require 'logger'

module Logging
  def self.logger
    @logger ||= new_logger
  end
  
  private
  
  def self.new_logger
    logger = Logger.new(STDOUT)
    logger.level = Logger::Severity::WARN
    logger
  end
end