
$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

require "net/irc"
include Net::IRC
include Constants

describe Message::ModeParser do
	it "should parse RFC2812+ correctly" do
		parser = Message::ModeParser.new
		
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
		parser = Message::ModeParser.new
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
		parser = Message::ModeParser.new
		parser.set(:PREFIX, '(qaohv)~&@%+')
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
