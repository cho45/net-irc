#!/usr/bin/env ruby
# vim:encoding=UTF-8:
=begin
# gig.rb

Github IRC Gateway

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" unless defined? ::Encoding

require "rubygems"
require "net/irc"
require "logger"
require "pathname"
require "libxml"
require "ostruct"
require 'time'

class ServerLogIrcGateway < Net::IRC::Server::Session
	def server_name
		"github"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		@opts.main_channel || "#github"
	end

	def initialize(*args)
		super
		@last_retrieved = Time.at(0)
	end

	def on_disconnected
		@retrieve_thread.kill rescue nil
	end

	def on_user(m)
		super
		@real, *@opts = @real.split(/\s+/)
		@opts = OpenStruct.new @opts.inject({}) {|r, i|
			key, value = i.split("=", 2)
			r.update key => case value
				when nil                      then true
				when /\A\d+\z/                then value.to_i
				when /\A(?:\d+\.\d*|\.\d+)\z/ then value.to_f
				else                               value
			end
		}

		@retrieve_thread = Thread.start do
			loop do
				@log.info 'retrieveing feed...'
				doc = LibXML::XML::Document.file("http://github.com/#{@real}.private.atom?token=#{@pass}")
				ns  = %w|a:http://www.w3.org/2005/Atom|
				doc.find('/a:feed/a:entry', ns).each do |n|
					datetime = Time.parse n.find('string(a:published)', ns)
					next if datetime < @last_retrieved

					id       = n.find('string(a:id)', ns)
					title    = n.find('string(a:title)', ns)
					author   = n.find('string(a:author/a:name)', ns)
					link     = n.find('string(a:link/@href)', ns)

					post author, PRIVMSG, main_channel, "#{title} \00314#{link}\017"
				end

				@last_retrieved = Time.now
				@log.info 'sleep'
				sleep 30
			end
		end
	end
end

if __FILE__ == $0
	require "optparse"

	opts = {
		:port  => 16705,
		:host  => "localhost",
		:log   => nil,
		:debug => false,
		:foreground => false,
	}

	OptionParser.new do |parser|
		parser.instance_eval do
			self.banner  = <<-EOB.gsub(/^\t+/, "")
				Usage: #{$0} [opts]

			EOB

			separator ""

			separator "Options:"
			on("-p", "--port [PORT=#{opts[:port]}]", "port number to listen") do |port|
				opts[:port] = port
			end

			on("-h", "--host [HOST=#{opts[:host]}]", "host name or IP address to listen") do |host|
				opts[:host] = host
			end

			on("-l", "--log LOG", "log file") do |log|
				opts[:log] = log
			end

			on("--debug", "Enable debug mode") do |debug|
				opts[:log]   = $stdout
				opts[:debug] = true
			end

			on("-f", "--foreground", "run foreground") do |foreground|
				opts[:log]        = $stdout
				opts[:foreground] = true
			end

			parse!(ARGV)
		end
	end

	opts[:logger] = Logger.new(opts[:log], "daily")
	opts[:logger].level = opts[:debug] ? Logger::DEBUG : Logger::INFO

	def daemonize(foreground=false)
		trap("SIGINT")  { exit! 0 }
		trap("SIGTERM") { exit! 0 }
		trap("SIGHUP")  { exit! 0 }
		return yield if $DEBUG || foreground
		Process.fork do
			Process.setsid
			Dir.chdir "/"
			File.open("/dev/null") {|f|
				STDIN.reopen  f
				STDOUT.reopen f
				STDERR.reopen f
			}
			yield
		end
		exit! 0
	end

	daemonize(opts[:debug] || opts[:foreground]) do
		Net::IRC::Server.new(opts[:host], opts[:port], ServerLogIrcGateway, opts).start
	end
end

 
