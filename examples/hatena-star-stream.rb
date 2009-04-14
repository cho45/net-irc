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
require "sdbm"
require "tmpdir"
require "nkf"
require "hpricot"
WWW::Mechanize.html_parser = Hpricot

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
		@ua.max_history = 1
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
			loop do
				begin
					login
					@log.info "getting report..."
					@ua.get("http://s.hatena.ne.jp/#{@real}/report")
					entries = @ua.page.root.search("#main span.entry-title a").map {|a|
						a['href']
					}

					@log.info "getting stars... #{entries.length}"
					stars = retrive_stars(entries)

					db = SDBM.open("#{Dir.tmpdir}/#{@real}.db", 0666)
					entries.reverse_each do |entry|
						next if stars[entry].empty?
						i = 0
						s = stars[entry].select {|star|
							id = "#{entry}::#{i}"
							i += 1
							if db.include?(id)
								false
							else
								db[id] = "1"
								true
							end
						}

						post server_name, NOTICE, main_channel, "↓ #{entry} #{title(entry)}" if s.length > 0

						s.each do |star|
							post server_name, NOTICE, main_channel, "id:%s \x03%d%s%s\x030 %s" % [
								star.name,
								Star::Colors[star.color],
								((star.color == "normal") ? "☆" : "★") * ([star.count, 10].min),
								(star.count > 10) ? "(...#{star.count})" : "",
								star.quote
							]
						end
					end

				rescue Exception => e
					@log.error e.inspect
					@log.error e.backtrace
				ensure
					db.close rescue nil
				end
				sleep 60 * 5
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
			if i["stars"].any? {|star| star.kind_of? Numeric }
				i = JSON.load(@ua.get("http://s.hatena.ne.jp/entry.json?uri=#{URI.escape(i["uri"])}").body)["entries"].first
			end
			stars = []

			if i["colored_stars"]
				i["colored_stars"].each do |s|
					s["stars"].each do |j|
						stars << Star.new(j, s["color"])
					end
				end
			end

			i["stars"].each do |j|
				star = Star.new(j)
				if star.quote.empty? && stars.last && stars.last.name == star.name && stars.last.color == "normal"
					stars.last.count += 1
				else
					stars << star
				end
			end
			r.update(i["uri"] => stars)
		}
		if n < entries.length
			ret.update retrive_stars(entries, n)
		end
		ret
	end

	def title(url)
		uri = URI(url)
		@ua.get(uri)

		text = ""
		case
		when uri.fragment
			fragment =  @ua.page.root.at("//*[@name = '#{uri.fragment}']") || @ua.page.root.at("//*[@id = '#{uri.fragment}']")

			text = fragment.inner_text + fragment.following.text + fragment.parent.following.text
		when uri.to_s =~ %r|^http://h.hatena.ne.jp/[^/]+/\d+|
			text = @ua.page.root.at("#main .entries .entry .list-body div.body").inner_text
		else
			text = @ua.page.root.at("//title").inner_text
		end
		text.gsub!(/\s+/, " ")
		text.strip!
		NKF.nkf("-w", text).split(//)[0..30].join
	rescue Exception => e
		@log.debug ["title:", e.inspect]
		""
	end

	def login
		@log.info "logging in as #{@real}"
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

	class Star < OpenStruct
		Colors = {
			"blue"   => 2,
			"green"  => 3,
			"red"    => 4,
			"normal" => 8,
		}

		def initialize(obj, col="normal")
			super(obj)
			self.count = obj["count"].to_i  + 1
			self.color = col
		end
	end
end

if __FILE__ == $0
	require "optparse"

	opts = {
	:port       => 16702,
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
