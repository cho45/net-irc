#!/usr/bin/env ruby
# vim:fileencoding=UTF-8:

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" if RUBY_VERSION < "1.9" # json use this

require "rubygems"
require "net/irc"
require "sdbm"
require "tmpdir"
require "uri"
require "mechanize"
require "rexml/document"

class GmailNotifier < Net::IRC::Server::Session
	def server_name
		"gmail"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#gmail"
	end

	def initialize(*args)
		super
		@agent = WWW::Mechanize.new
	end

	def on_user(m)
		super
		post @prefix, JOIN, main_channel
		post server_name, MODE, main_channel, "+o", @prefix.nick

		@real, *@opts = @opts.name || @real.split(/\s+/)
		@opts ||= []

		start_observer
	end

	def on_disconnected
		@observer.kill rescue nil
	end

	def on_privmsg(m)
		super
		case m[1]
		when 'list'
			check_mail
		end
	end

	def on_ctcp(target, message)
	end

	def on_whois(m)
	end

	def on_who(m)
	end

	def on_join(m)
	end

	def on_part(m)
	end

	private
	def start_observer
		@observer = Thread.start do
			Thread.abort_on_exception = true
			loop do
				begin
					@agent.auth(@real, @pass)
					page = @agent.get(URI.parse("https://gmail.google.com/gmail/feed/atom"))
					feed = REXML::Document.new page.body
					db = SDBM.open("#{Dir.tmpdir}/#{@real}.db", 0666)
					feed.get_elements('/feed/entry').reverse.each do |item|
						id = item.text('id')
						if db.include?(id)
							next
						else
							db[id] = "1"
						end
						post server_name, PRIVMSG, main_channel, "Subject: #{item.text('title')} From: #{item.text('author/name')}"
						post server_name, PRIVMSG, main_channel, "#{item.text('summary')}"
					end
				rescue Exception => e
					@log.error e.inspect
				ensure
					db.close rescue nil
				end
				sleep 60 * 5
			end
		end
	end

	def check_mail
		begin
			@agent.auth(@real, @pass)
			page = @agent.get(URI.parse("https://gmail.google.com/gmail/feed/atom"))
			feed = REXML::Document.new page.body
			db = SDBM.open("#{Dir.tmpdir}/#{@real}.db", 0666)
			feed.get_elements('/feed/entry').reverse.each do |item|
				id = item.text('id')
				if db.include?(id)
					#next
				else
					db[id] = "1"
				end
				post server_name, PRIVMSG, main_channel, "Subject: #{item.text('title')} From: #{item.text('author/name')}"
				post server_name, PRIVMSG, main_channel, "#{item.text('summary')}"
			end
		rescue Exception => e
			@log.error e.inspect
		ensure
			db.close rescue nil
		end
	end
end

if __FILE__ == $0
	require "optparse"

	opts = {
	:port       => 16800,
	:host       => "localhost",
	:log        => nil,
	:debug      => false,
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
		Net::IRC::Server.new(opts[:host], opts[:port], GmailNotifier, opts).start
	end
end

# Local Variables:
# coding: utf-8
# End:
