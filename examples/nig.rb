#!/usr/bin/env ruby
=begin

# nig.rb

nowa IRC Gateway

## Launch

	$ ruby nig.rb # daemonized

If you want to help:

	$ ruby nig.rb --help

## Configuration

Options specified by after irc realname.

Configuration example for Tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	nowa {
		host: localhost
		port: 16671
		name: username@example.com athack
		password: password on nowa
		in-encoding: utf8
		out-encoding: utf8
	}

### athack

If `athack` client option specified,
all nick in join message is leading with @.

So if you complemente nicks (ex. Irssi),
it's good for twitter like reply command (@nick).

In this case, you will see torrent of join messages after connected,
because NAMES list can't send @ leading nick (it interpreted op.)

## Licence

Ruby's by cho45

=end

$LOAD_PATH << File.dirname(__FILE__)

require "tig.rb"

class NowaIrcGateway < TwitterIrcGateway
	def server_name
		"nowagw"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#nowa"
	end

	def api_base
		URI("https://api.nowa.jp/")
	end

	def api_source
		"nig.rb"
	end

	def jabber_bot_id
		nil
	end
end

if __FILE__ == $0
	require "optparse"

	opts = {
		:port  => 16671,
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
		Net::IRC::Server.new(opts[:host], opts[:port], NowaIrcGateway, opts).start
	end
end

