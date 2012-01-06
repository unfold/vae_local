class Servlet < Mongrel::HttpHandler

  def process(request, response)
    response.start do |head,out|
      head["Content-Type"] = "text/html"
      out << "Servlet"
    end
  end
  
end

class FileNotFound < ArgumentError
end