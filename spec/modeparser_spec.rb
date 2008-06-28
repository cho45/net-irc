
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
