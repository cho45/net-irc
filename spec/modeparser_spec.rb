
$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

require "net/irc"
include Net::IRC
include Constants


describe Message::ModeParser do
	it "should parse RFC1459 correctly" do
		Message::ModeParser::RFC1459::Channel.parse("#Finish +im")[:positive].should        == [[:i, nil], [:m, nil]]
		Message::ModeParser::RFC1459::Channel.parse("#Finish +o Kilroy")[:positive].should  == [[:o, "Kilroy"]]
		Message::ModeParser::RFC1459::Channel.parse("#Finish +v Kilroy")[:positive].should  == [[:v, "Kilroy"]]
		Message::ModeParser::RFC1459::Channel.parse("#Fins -s")[:negative].should           == [[:s, nil]]
		Message::ModeParser::RFC1459::Channel.parse("#42 +k oulu")[:positive].should        == [[:k, "oulu"]]
		Message::ModeParser::RFC1459::Channel.parse("#eu-opers +l 10")[:positive].should    == [[:l, "10"]]
		Message::ModeParser::RFC1459::Channel.parse("&oulu +b")[:positive].should           == [[:b, nil]]
		Message::ModeParser::RFC1459::Channel.parse("&oulu +b *!*@*")[:positive].should     == [[:b, "*!*@*"]]
		Message::ModeParser::RFC1459::Channel.parse("&oulu +b *!*@*.edu")[:positive].should == [[:b, "*!*@*.edu"]]

		Message::ModeParser::RFC1459::Channel.parse("#foo +ooo foo bar baz").should   == {
			:positive => [[:o, "foo"], [:o, "bar"], [:o, "baz"]],
			:negative => [],
		}
		Message::ModeParser::RFC1459::Channel.parse("#foo +oo-o foo bar baz").should  == {
			:positive => [[:o, "foo"], [:o, "bar"]],
			:negative => [[:o, "baz"]],
		}
		Message::ModeParser::RFC1459::Channel.parse("#foo -oo+o foo bar baz").should  == {
			:positive => [[:o, "baz"]],
			:negative => [[:o, "foo"], [:o, "bar"]],
		}
		Message::ModeParser::RFC1459::Channel.parse("#foo +imv foo").should  == {
			:positive => [[:i, nil], [:m, nil], [:v, "foo"]],
			:negative => [],
		}

		Message::ModeParser::RFC1459::User.parse("WIZ -w")[:negative].should   == [[:w, nil]]
		Message::ModeParser::RFC1459::User.parse("ANGEL +i")[:positive].should == [[:i, nil]]
		Message::ModeParser::RFC1459::User.parse("WIZ -o")[:negative].should   == [[:o, nil]]
	end
end

describe Message::ModeParser::ISupport do
	it "should parse RFC2812+ correctly" do
		parser = Message::ModeParser::ISupport.new
		
		parser.parse("#Finish +im")[:positive].should        == [[:i, nil], [:m, nil]]
		parser.parse("#Finish +o Kilroy")[:positive].should  == [[:o, "Kilroy"]]
		parser.parse("#Finish +v Kilroy")[:positive].should  == [[:v, "Kilroy"]]
		parser.parse("#Fins -s")[:negative].should           == [[:s, nil]]
		parser.parse("#42 +k oulu")[:positive].should        == [[:k, "oulu"]]
		parser.parse("#eu-opers +l 10")[:positive].should    == [[:l, "10"]]
		parser.parse("&oulu +b")[:positive].should           == [[:b, nil]]
		parser.parse("&oulu +b *!*@*")[:positive].should     == [[:b, "*!*@*"]]
		
		parser.parse("&oulu +b *!*@*.edu")[:positive].should == [[:b, "*!*@*.edu"]]
		parser.parse("#oulu +e")[:positive].should           == [[:e, nil]]
		parser.parse("#oulu +e *!*@*.edu")[:positive].should == [[:e, "*!*@*.edu"]]
		parser.parse("#oulu +I")[:positive].should           == [[:I, nil]]
		parser.parse("#oulu +I *!*@*.edu")[:positive].should == [[:I, "*!*@*.edu"]]
		parser.parse("#oulu +R")[:positive].should           == [[:R, nil]]
		parser.parse("#oulu +R *!*@*.edu")[:positive].should == [[:R, "*!*@*.edu"]]

		parser.parse("#foo +ooo foo bar baz").should   == {
			:positive => [[:o, "foo"], [:o, "bar"], [:o, "baz"]],
			:negative => [],
		}
		parser.parse("#foo +oo-o foo bar baz").should  == {
			:positive => [[:o, "foo"], [:o, "bar"]],
			:negative => [[:o, "baz"]],
		}
		parser.parse("#foo -oo+o foo bar baz").should  == {
			:positive => [[:o, "baz"]],
			:negative => [[:o, "foo"], [:o, "bar"]],
		}
		parser.parse("#foo +imv foo").should  == {
			:positive => [[:i, nil], [:m, nil], [:v, "foo"]],
			:negative => [],
		}
		
		parser.parse("#foo +lk 10 foo").should  == {
			:positive => [[:l, "10"], [:k, "foo"]],
			:negative => [],
		}
		parser.parse("#foo -l+k foo").should  == {
			:positive => [[:k, "foo"]],
			:negative => [[:l, nil]],
		}
		parser.parse("#foo +ao foo").should  == {
			:positive => [[:a, nil], [:o, "foo"]],
			:negative => [],
		}
	end

	it "should parse modes of Hyperion ircd correctly" do
		parser = Message::ModeParser::ISupport.new
		parser.set(:CHANMODES, 'bdeIq,k,lfJD,cgijLmnPQrRstz')
		
		parser.parse("#Finish +im")[:positive].should        == [[:i, nil], [:m, nil]]
		parser.parse("#Finish +o Kilroy")[:positive].should  == [[:o, "Kilroy"]]
		parser.parse("#Finish +v Kilroy")[:positive].should  == [[:v, "Kilroy"]]
		parser.parse("#Fins -s")[:negative].should           == [[:s, nil]]
		parser.parse("#42 +k oulu")[:positive].should        == [[:k, "oulu"]]
		parser.parse("#eu-opers +l 10")[:positive].should    == [[:l, "10"]]
		parser.parse("&oulu +b")[:positive].should           == [[:b, nil]]
		parser.parse("&oulu +b *!*@*")[:positive].should     == [[:b, "*!*@*"]]
		parser.parse("&oulu +b *!*@*.edu")[:positive].should == [[:b, "*!*@*.edu"]]
		
		parser.parse("#oulu +e")[:positive].should           == [[:e, nil]]
		parser.parse("#oulu +e *!*@*.edu")[:positive].should == [[:e, "*!*@*.edu"]]
		parser.parse("#oulu +I")[:positive].should           == [[:I, nil]]
		parser.parse("#oulu +I *!*@*.edu")[:positive].should == [[:I, "*!*@*.edu"]]

		parser.parse("#foo +ooo foo bar baz").should   == {
			:positive => [[:o, "foo"], [:o, "bar"], [:o, "baz"]],
			:negative => [],
		}
		parser.parse("#foo +oo-o foo bar baz").should  == {
			:positive => [[:o, "foo"], [:o, "bar"]],
			:negative => [[:o, "baz"]],
		}
		parser.parse("#foo -oo+o foo bar baz").should  == {
			:positive => [[:o, "baz"]],
			:negative => [[:o, "foo"], [:o, "bar"]],
		}
		parser.parse("#foo +imv foo").should  == {
			:positive => [[:i, nil], [:m, nil], [:v, "foo"]],
			:negative => [],
		}
		
		parser.parse("#foo +lk 10 foo").should  == {
			:positive => [[:l, "10"], [:k, "foo"]],
			:negative => [],
		}
		parser.parse("#foo -l+k foo").should  == {
			:positive => [[:k, "foo"]],
			:negative => [[:l, nil]],
		}
		parser.parse("#foo +cv foo").should  == {
			:positive => [[:c, nil], [:v, "foo"]],
			:negative => [],
		}
	end

	it "should parse modes of Unreal ircd correctly" do
		parser = Message::ModeParser::ISupport.new
		parser.set(:PREFIX, '(qaohv)~&@%+ ')
		parser.set(:CHANMODES, 'beI,kfL,lj,psmntirRcOAQKVCuzNSMTG')
		
		parser.parse("#Finish +im")[:positive].should        == [[:i, nil], [:m, nil]]
		parser.parse("#Finish +o Kilroy")[:positive].should  == [[:o, "Kilroy"]]
		parser.parse("#Finish +v Kilroy")[:positive].should  == [[:v, "Kilroy"]]
		parser.parse("#Fins -s")[:negative].should           == [[:s, nil]]
		parser.parse("#42 +k oulu")[:positive].should        == [[:k, "oulu"]]
		parser.parse("#eu-opers +l 10")[:positive].should    == [[:l, "10"]]
		parser.parse("&oulu +b")[:positive].should           == [[:b, nil]]
		parser.parse("&oulu +b *!*@*")[:positive].should     == [[:b, "*!*@*"]]
		parser.parse("&oulu +b *!*@*.edu")[:positive].should == [[:b, "*!*@*.edu"]]
		
		parser.parse("#oulu +e")[:positive].should           == [[:e, nil]]
		parser.parse("#oulu +e *!*@*.edu")[:positive].should == [[:e, "*!*@*.edu"]]
		parser.parse("#oulu +I")[:positive].should           == [[:I, nil]]
		parser.parse("#oulu +I *!*@*.edu")[:positive].should == [[:I, "*!*@*.edu"]]

		parser.parse("#foo +ooo foo bar baz").should   == {
			:positive => [[:o, "foo"], [:o, "bar"], [:o, "baz"]],
			:negative => [],
		}
		parser.parse("#foo +oo-o foo bar baz").should  == {
			:positive => [[:o, "foo"], [:o, "bar"]],
			:negative => [[:o, "baz"]],
		}
		parser.parse("#foo -oo+o foo bar baz").should  == {
			:positive => [[:o, "baz"]],
			:negative => [[:o, "foo"], [:o, "bar"]],
		}
		parser.parse("#foo +imv foo").should  == {
			:positive => [[:i, nil], [:m, nil], [:v, "foo"]],
			:negative => [],
		}
		
		parser.parse("#foo +lk 10 foo").should  == {
			:positive => [[:l, "10"], [:k, "foo"]],
			:negative => [],
		}
		parser.parse("#foo -l+k foo").should  == {
			:positive => [[:k, "foo"]],
			:negative => [[:l, nil]],
		}
		parser.parse("#foo -q+ah foo bar baz").should  == {
			:positive => [[:a, "bar"], [:h, "baz"]],
			:negative => [[:q, "foo"]],
		}
		parser.parse("#foo +Av foo").should  == {
			:positive => [[:A, nil], [:v, "foo"]],
			:negative => [],
		}
	end
end
