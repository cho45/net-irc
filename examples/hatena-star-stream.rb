#!/usr/bin/env ruby
=begin


## Licence

Ruby's by cho45

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" # json use this

require "rubygems"
require "json"
require "net/irc"
require "mechanize"

class HatenaStarStream < Net::IRC::Server::Session
	def server_name
		"hatenastarstream"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#star"
	end

	def initialize(*args)
		super
		@ua = WWW::Mechanize.new
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
		@ua.instance_eval do
			get "http://h.hatena.ne.jp/"
			form = page.forms.find {|f| f.action == "/entry" }
			form["body"] = m[1]
			submit form
		end
		post server_name, NOTICE, main_channel, "posted"
	rescue Exception => e
		log e.inspect
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
			reads = []
			loop do
				login
				@ua.get("http://s.hatena.ne.jp/#{@real}/report")
				entries = @ua.page.root.search("#main span.entry-title a").map {|a|
					a[:href]
				}

				stars = retrive_stars(entries)

				entries.reverse_each do |entry|
					next if stars[entry].empty?
					s, quoted = stars[entry].select {|star|
						id = "#{entry}::#{star.values_at("name", "quote").inspect}"
						if reads.include?(id)
							false
						else
							reads << id
							reads = reads.last(500)
							true
						end
					}.partition {|star| star["quote"].empty? }
					post server_name, NOTICE, main_channel, entry if s.length + quoted.length > 0
					post server_name, NOTICE, main_channel, s.map {|star| "id:#{star["name"]}" }.join(" ") unless s.empty?

					quoted.each do |star|
						post server_name, NOTICE, main_channel, "id:#{star["name"]} '#{star["quote"]}'"
					end
				end

				sleep 60
			end
		end
	end

	def retrive_stars(entries, n=0)
		uri = "http://s.hatena.ne.jp/entries.json?"
		while uri.length < 1800 and n < entries.length
			uri << "uri=#{URI.escape(entries[n], /[^-.!~*'()\w]/n)}&"
			n += 1
		end
		ret = JSON.load(@ua.get(uri).body)["entries"].inject({}) {|r,i|
			r.update(i["uri"] => i["stars"])
		}
		if n < entries.length
			ret.update retrive_stars(entries, n)
		end
		ret
	end

	def login
		@ua.get "https://www.hatena.ne.jp/login?backurl=http%3A%2F%2Fd.hatena.ne.jp%2F"
		return if @ua.page.forms.empty?

		form             = @ua.page.forms.first
		form["name"]     = @real
		form["password"] = @pass

		@ua.submit(form)

		unless @ua.page.forms.empty?
			post server_name, ERR_PASSWDMISMATCH, ":Password incorrect"
			finish
		end
	end
end

if __FILE__ == $0
	require "optparse"

	opts = {
	:port       => 16700,
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
		Net::IRC::Server.new(opts[:host], opts[:port], HatenaStarStream, opts).start
	end
end

# Local Variables:
# coding: utf-8
# End:
