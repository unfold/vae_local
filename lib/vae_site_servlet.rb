class VaeSiteServlet < Servlet      
  
  def bundle_changed_source_files(source_files)
    source_files ||= []
    changed = nil
    $biglock.synchronize {
      changed = $changed
      $changed = {}
    }
    source_files.concat(changed.map { |filename,action|
      get_source_file(filename, (action == :deleted))
    }).reject { |src| src.nil? }
  end
  
  def get_source_file(path, optional = false)
    full_path = nil
    if File.exists?($site.root + path)
      full_path = path
    else
      SERVER_PARSED.each do |ext|
        if full_path.nil? and File.exists?($site.root + path + ext)
          full_path = path + ext
        end
      end
    end
    if full_path.nil? and !optional
      raise FileNotFound
    elsif full_path
      begin
        file = File.read($site.root + full_path)
        md5 = Digest::MD5.hexdigest(file)
      rescue Errno::EISDIR
        return nil
      end
    else
      full_path = path
      md5 = ""
      file = ""
    end
    if $cache[full_path] != md5
      $cache[full_path] = md5
      [ full_path, file ]
    else
      nil
    end
  end
  
  def fetch_from_vae(wb_req, method, source_files = nil)
    uri = wb_req.params["REQUEST_URI"] + ((wb_req.params["REQUEST_URI"] =~ /\?/) ? "&" : "?") + "__vae_local=#{$site.session_id}"
    source_files = bundle_changed_source_files(source_files)
    if method == "GET"
      if source_files.is_a?(Array) and source_files.size > 0
        req = Net::HTTP::Post.new(uri)
        source_files.map { |src| puts "sending #{src[0]}" }
        req.body = source_files.collect { |src| "__vae_local_files[#{src[0]}]=#{CGI.escape(src[1])}" }.join("&")
      else
        req = Net::HTTP::Get.new(uri)
      end
    else
      if source_files.is_a?(Array) and source_files.size > 0
        fetch_from_vae(wb_req, "GET", source_files)
      end
      req = Net::HTTP::Post.new(uri)
      req.body = wb_req.body.read
    end
    req['cookie'] = wb_req.params["HTTP_COOKIE"]
    if wb_req.params['HTTP_X_REQUESTED_WITH']
      req['X-Requested-With'] = wb_req.params['HTTP_X_REQUESTED_WITH']
    end
    res = $site.fetch_from_server(req)
    if res.body =~ /__vae_local_needs=(.*)/
      begin
        return fetch_from_vae(wb_req, method, [ get_source_file($1) ])
      rescue FileNotFound
        puts "*\n* Could not find #{$1} -- giving up!\n*"
        return $site.fetch_from_server(Net::HTTP::Get.new("/error_pages/not_found.html"))
      end
    end
    res
  end
  
  def fetch_from_vae_and_include_source_of_current_page(req, method)
    fetch_from_vae(req, method, [ find_source_file_from_path(req.params["REQUEST_URI"]), get_source_file("/__vae.php", true), get_source_file("/__verb.php", true) ])
  end
  
  def find_source_file_from_path(path)
    path_parts = path.split("/").reject { |part| part.length < 1 }
    local_path = ""
    loop do 
      gotit = false
      if part = path_parts.shift
        new_local_path = local_path + "/" + part
        (SERVER_PARSED + [ "" ]).each do |ext|
          if File.exists?($site.root + new_local_path + ext)
            gotit = true
            local_path = new_local_path + ext
          end
        end
      end
      break unless gotit
    end
    return nil unless local_path.length > 0
    get_source_file(local_path)
  end
  
  def not_modified?(req, res, mtime, etag)
    return true if (ims = req.params['IF_MODIFIED_SINCE']) && Time.parse(ims) >= mtime
    return true if (inm = req.params['IF_NONE_MATCH']) && WEBrick::HTTPUtils::split_header_value(inm).member?(etag)
    false
  end
  
  def render_sass(local_path)
    begin
      options = Compass.sass_engine_options
      options[:load_paths] << File.dirname(local_path) 
      engine = Sass::Engine.new(open(local_path, "rb").read, options)
      engine.render
    rescue Sass::SyntaxError => e
      e.message
    end
  end

  def process(request, response)
    serve(request, response)
    response.finished
  end
  
  def serve(req, res)
    res.status = 200
    local_path = ($site.root+req.params["REQUEST_URI"] || "/").split("?").first
    if File.exists?(local_path) and !File.directory?(local_path) and !server_parsed?(local_path)
      st = File::stat(local_path)
      mtime = st.mtime
      etag = sprintf("%x-%x-%x", st.ino, st.size, st.mtime.to_i)
      res.header['etag'] = etag
      if not_modified?(req, res, mtime, etag)
        puts "#{req.params["REQUEST_URI"]} not modified"
        res.status = 304
      else
        mtype = WEBrick::HTTPUtils::mime_type(local_path, WEBrick::HTTPUtils::DefaultMimeTypes)
        res.header['last-modified'] = mtime.httpdate
        if req.params["REQUEST_URI"] =~ /.sass$/
          res.header['Content-Type'] = "text/css"
          res.body << render_sass(local_path)
        else
          res.header['Content-Type'] = mtype
          res.body << open(local_path, "rb").read
        end
        puts "#{req.params["REQUEST_URI"]} local asset"
      end
    else
      if req.params["REQUEST_URI"] =~ /^\/__data\// or req.params["REQUEST_URI"] =~ /^\/__assets\//
        from_vae = { 'location' => "http://#{$site.subdomain}.vaesite.com#{req.params["REQUEST_URI"]}"}
        puts "#{req.params["REQUEST_URI"]} static asset"
      else
        from_vae = fetch_from_vae_and_include_source_of_current_page(req, req.params["REQUEST_METHOD"])
        if from_vae['location']
          puts "#{req.params["REQUEST_URI"]} redirecting to #{from_vae['location']}"
        end
      end
      if from_vae['location']
        res.body << "<p>Redirecting to <a href=\"#{from_vae['location']}\">#{from_vae['location']}</a>"
        res.status = 302
        res.header['Location'] = from_vae['location']    
      else
        res.header['Etag'] = from_vae['etag']
        res.header['Last-Modified'] = from_vae['last-modified']
        res.header['Content-Type'] = from_vae['content-type']
        res.header['Content-Disposition'] = from_vae['content-disposition']
        res.header['Set-Cookie'] = from_vae['set-cookie']
        puts "#{req.params["REQUEST_URI"]} rendering"
        res.body << from_vae.body
      end
    end
  end
  
  def server_parsed?(path)
    SERVER_PARSED.each do |ext|
      return true if Regexp.new("#{ext}$").match(path)
    end
    false
  end
  
end

