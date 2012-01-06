#!/usr/bin/env ruby -W0

THIS_FILE = File.symlink?(__FILE__) ? File.readlink(__FILE__) : __FILE__
Dir.glob(File.dirname(THIS_FILE) + '/lib/vendor/*/lib').each { |dir| $:.unshift(dir) }
$:.unshift File.dirname(THIS_FILE) + '/lib'

require 'vae'

VaeLocal.run_trapping_exceptions!