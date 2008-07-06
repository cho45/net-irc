class Net::IRC::Message::ModeParser

	ONE_PARAM_MASK         = 0
	ONE_PARAM              = 1
	ONE_PARAM_FOR_POSITIVE = 2
	NO_PARAM               = 3

	def initialize
		@modes    = {}
		@op_marks = {}

		# Initialize for ircd 2.11 (RFC2812+)
		set(:CHANMODES, 'beIR,k,l,imnpstaqr')
		set(:PREFIX, '(ov)@+')
	end

	def set(key, value)
		case key
		when :PREFIX
			if value =~ /^\(([a-zA-Z]+)\)(.+)$/
				@op_marks = {}
				key, value = Regexp.last_match[1], Regexp.last_match[2]
				key.scan(/./).zip(value.scan(/./)) {|pair|
					@op_marks[pair[0].to_sym] = pair[1]
				}
			end
		when :CHANMODES
			@modes = {}
			value.split(/,/).each_with_index do |s,kind|
				s.scan(/./).each {|c|
					@modes[c.to_sym] = kind
				}
			end
		end
	end

	def parse(arg)
		params = arg.kind_of?(Net::IRC::Message) ? arg.to_a : arg.split(/\s+/)
		params.shift

		ret = {
			:positive => [],
			:negative => [],
		}

		current = ret[:positive]
		until params.empty?
			s = params.shift
			s.scan(/./).each do |c|
				c = c.to_sym
				case c
				when :+
					current = ret[:positive]
				when :-
					current = ret[:negative]
				else
					case @modes[c]
					when ONE_PARAM_MASK,ONE_PARAM
						current << [c, params.shift]
					when ONE_PARAM_FOR_POSITIVE
						if current.equal?(ret[:positive])
							current << [c, params.shift]
						else
							current << [c, nil]
						end
					when NO_PARAM
						current << [c, nil]
					else
						if @op_marks[c]
							current << [c, params.shift]
						end
					end
				end
			end
		end

		ret
	end
end
