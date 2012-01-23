require 'cgi'
require 'digest/md5'
require 'mongrel'
require 'net/http'
require 'net/https'
require 'optparse'
require 'thread'
require 'webrick'
require 'yaml'

require 'directory_watcher'
require 'highline/import'
require 'compass'
require 'haml'

require 'logging'
require 'servlet'
require 'site'
require 'vae_error'
require 'vae_site_servlet'
require 'vae_local_servlet'
require 'version'

SERVER_PARSED = [ ".html", ".haml", ".php", ".xml", ".rss", ".pdf.haml", ".pdf.haml.php", ".haml.php" ]
SERVER_PARSED_GLOB = [ "**/*.html", "**/*.haml", "**/*.php", "**/*.xml", "**/*.rss", "**/*.pdf.haml", "**/*.pdf.haml.php", "**/*.haml.php" ]
BANNER = "Vae local preview server, version #{VER}"

class VaeLocal
  
  def fetch_from_vaeplatform(site, req)
    http = Net::HTTP.new("#{site}.vaeplatform.com", 443)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.start { |http|
      http.read_timeout = 120
      http.request(req)
    }
  end
  
  def get_credentials(site)
    credentials = {}

    # Subversion
    home = Dir.chdir { Dir.pwd }
    Dir.glob("#{home}/.subversion/auth/svn.simple/*").each do |file|
      credentials = parse_svn_auth_file(file)
      if credentials["svn:realmstring"] =~ /<http:\/\/svn(\.|_)#{site}.(vae|verb)site.com/ or credentials["svn:realmstring"] =~ /<http:\/\/#{site}(\.|_)svn.(vae|verb)site.com/
        return credentials
      end
    end

    # Git
    unless credentials["username"]
      credentials["username"] = `git config vae.username`.chomp
      credentials["password"] = `git config vae.password`.chomp
    end

    credentials
  end
  
  def parse_svn_auth_file(file)
    key = nil
    mode = nil
    params = {}
    File.read(file).each_line do |line|
      line.strip!
      if mode == :key
        key = line
        mode = nil
      elsif mode == :value
        params[key] = line
        mode = nil
      else
        if line[0,1] == "K"
          mode = :key
        elsif line[0, 1] == "V"
          mode = :value
        end
      end
    end
    params
  end
  
  def run!
    options = { :port => 9999 }
    ARGV.options  do |opts|
      opts.banner = BANNER + "\n\nUsage: vae [options]\n         starts a local development server\n       vae [options] deploy\n         promotes the source in Subversion repository to the FTP\n\n  If you are using the Vae Production environment features:\n       vae [options] stage\n         promotes the source in Subversion repository to the staging environment\n       vae [options] stagerelease\n         promotes the source in Subversion repository to the staging environment\n         and releases it to the production environment\n       vae [options] release\n         releases the current staging environment to the production environment\n       vae [options] rollback\n         rolls back the production environment to a previous release\n\nAvailable Options:"
      opts.on("-u","--username <username>","Your Vae username") { |o| options[:username] = o } 
      opts.on("-p","--port <port number>","Start server on this port") { |o| options[:port] = o } 
      opts.on("-r","--root <path to site root>","Path to the root of the local copy of your Vae site.") { |o| options[:site_root] = o }   
      opts.on("-s","--site <subdomain>","Vae subdomain for this site") { |o| options[:site] = o }  
      opts.on_tail("-h","--help", "Show this help message") { puts opts; exit }
      opts.parse!
    end
    options[:site_root] = Dir.pwd if options[:site_root].nil? # Git
    if options[:site_root] and (File.exists?("#{Dir.pwd}/__vae.yml") or File.exists?("#{Dir.pwd}/__verb.yml"))
      [ "verb", "vae" ].each do |name|
        if File.exists?("#{options[:site_root]}/__#{name}.yml")
          site_conf_file = File.read("#{options[:site_root]}/__#{name}.yml")
          site_conf = YAML.load(site_conf_file)
          options[:site] = site_conf[name]["site"] if site_conf[name] and site_conf[name]["site"]
        end
      end
    end
    options[:site] = `git config vae.site`.chomp unless options[:site]
    raise VaeError, "We could not determine the Vae subdomain for this site.  Please specify it manually by using the --site option or create a __vae.yml file within the site root." if options[:site].nil?
    unless options[:username]
      credentials = get_credentials(options[:site])
      options[:username] = credentials["username"]
      options[:password] = credentials["password"]
    end
    raise VaeError, "We could not determine the Vae username that you use.  Please specify it manually by using the --username option." if options[:username].nil?
    if options[:password].nil?
      options[:password] = ask("Please enter the Vae password for username #{options[:username]}:") {|q| q.echo = false}
    end
    if [ "deploy", "release", "rollback", "stage", "stagerelease" ].include?(ARGV.last)
      stagerelease(ARGV.last, options[:site], options[:username], options[:password])
      exit
    end
    raise VaeError, "You did not specify the path to the root of the local copy of your Vae site.  Please specify it manually by using the --root option or cd to the site root (and make sure it contains a __vae.yml file)." unless options[:site_root]
    raise VaeError, "You specified an invalid path to the local copy of your Vae site." unless File.exists?(options[:site_root])

    $biglock = Mutex.new
    dw = DirectoryWatcher.new options[:site_root], :interval => 1.0, :glob => SERVER_PARSED_GLOB, :pre_load => true
    dw.add_observer { |*args| 
      args.each { |event|
        path = event.path.gsub($site.root, "")
        $biglock.synchronize {
          $changed[path] = event.type
        }
      }
    }
    dw.start

    Dir.chdir File.dirname(__FILE__)
    puts BANNER
    puts "Vae is in action at http://localhost:#{options[:port]}/"  
    puts "  (hit Control+C to exit)"
    $site = Site.new(:subdomain => options[:site], :root => options[:site_root], :username => options[:username], :password => options[:password])
    $cache = {}
    $changed = {}
    $server = Mongrel::Configurator.new :host => "0.0.0.0", :port => options[:port] do
      listener do
        uri "/", :handler => VaeSiteServlet.new
        #uri "/__welcome/", :handler => VaeLocalServlet.new
      end
      trap("INT") { raise Mongrel::StopServer }
      run
    end

    begin
      $server.join
    rescue Mongrel::StopServer
      puts "Thanks for using Vae!"
    end
  end
  
  def stagerelease(action, site, username, password)
    if action == "deploy"
      action = "stage"
    elsif action == "stagerelease"
      stagerelease("stage", site, username, password)
      stagerelease("release", site, username, password)
      return
    end
    req = Net::HTTP::Post.new("/subversion/#{action}")
    req.body = "username=#{CGI.escape(username)}&password=#{CGI.escape(password)}"
    res = fetch_from_vaeplatform(site, req)
    if res.is_a?(Net::HTTPFound)
      raise VaeError, "Invalid username/password or insufficient permissions."
    else
      puts res.body
    end
  end
  
  def self.run_trapping_exceptions!
    begin
      v = VaeLocal.new
      v.run!
    rescue VaeError => e
      cmd = $0
      cmd = "vae" if cmd =~ /\.\.\/vae_local/
      puts "** Error:"
      puts "   " + e
      puts "Type #{cmd} --help for help."
    end
  end

end