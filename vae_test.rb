#!/usr/bin/env ruby

$:.unshift File.dirname(__FILE__) + '/lib'
require 'test/unit'
require 'vae'

class VaeTest < Test::Unit::TestCase
  
  def setup
  end
  
  def test_server_parsed
    servlet = VaeSiteServlet.new({})
    assert servlet.server_parsed?("cow.html")
    assert servlet.server_parsed?("cow.pdf.html")
    assert servlet.server_parsed?("cow.haml")
    assert servlet.server_parsed?("cow.xml")
    assert servlet.server_parsed?("cow.rss")
    assert servlet.server_parsed?("cow.php")
    assert servlet.server_parsed?("cow.haml.php")
    assert !servlet.server_parsed?("cow.sass")
    assert !servlet.server_parsed?("cow.gif")
    assert !servlet.server_parsed?("cow.html.gif")
    assert !servlet.server_parsed?("cow")
    assert !servlet.server_parsed?("cow.haml.php.jpg")
  end
  
end