package likehuman;

# Fixed to 1.9.x version by h4rry84
# likeHuman v 3.0.1
#
# This plugin was made by taking some parts of kadiliman's ChatBot and the "match" sub of hakore's ReactOnNPC plugins.
# Change it as your will.
# This plugin is FREE, so you can do whatever(yes, whatever) you want with it.
# By Buggless
#
# Working on openkore 1.9.x and 1.6.8+
#
# It will run only when AI is on.
# An overlap on ChaCount conditions on same messages will cause last block to replace the first response (former one).
# Usage:
# on config.txt should include:
#
# likeHumanOn (0|1)            is a flag to turn on (1) and off (0) plugin
# likeHumanInLockOnly (0|1)            is a flag to turn on (1) and off (0) responses only on lockMap
# likeHumanConsole (0|1)            is a flag to turn on (1) and off (0) console messages
# likeHumanIgnore <semicolon_separated_list_of_names_also_regex>
# likeHumanStopAfter <number_of_max_responses_to_same_user>
# likeHumanRealIgnoreOn (0|1)            is a flag to turn on (1) and off (0) the ignore openkore option after
#                                                 "likeHumanStopAfter" max responses are reached or in case "endings" condition
#                                                 is accomplished.
#
# likeHuman {
#    questions <semicolon_separated_possible_from_msg_also_regex>
#    answers <semicolon_separated_possible_responses>
#    onPub (0|1)            is a flag to turn set (1) or unset (0) this questions check on Public Chat
#    distance <max distance> is the max distance to the char that makes the pubMsg, you will cosider to make a response to
#    onSystem (0|1)            is a flag to turn set (1) or unset (0) this questions check on System Chat
#    onGuild (0|1)            is a flag to turn set (1) or unset (0) this questions check on Guild Chat
#    onParty (0|1)            is a flag to turn set (1) or unset (0) this questions check on Party Chat
#    onPM (0|1)            is a flag to turn set (1) or unset (0) this questions check on Private Msg Chat
#    chatCount <range>      is a range to set how many times you will response to the same user
#    endings <semicolon_separated_possible_close_chat_responses>
# }
#

use strict;
use Plugins;
use Globals;
use Log qw(message warning error debug);
use Misc;
use Network;
use Network::Send;
use Utils;

my %chatcount;
my %chatended;
my @ignorelist;
my %totalcount;

my $questionlist;
my @questions;
my $answerlist;
my @answers;
my $answer;
my $sanswer = 0;
my $endingslist;
my @endings;

my $prefix = "likeHuman_";

Plugins::register('likehuman', 'Human-Chat-Like behavior bot', \&Unload);

my $hooks = Plugins::addHooks(
                                ['packet_pubMsg', \&onMsg, undef],
                                ['packet_privMsg', \&onMsg, undef],
                                ['packet_selfChat', \&onMsg, undef],
                                ['packet_partyMsg', \&onMsg, undef],
                                ['packet_guildMsg', \&onMsg, undef],
                                ['AI_post', \&AI_post, undef]
                        );

sub Unload {
        Plugins::delHooks($hooks);
}

sub onMsg {

      return unless ($main::conState == 5);
        return if (!$config{'likeHumanOn'});
        return unless $AI;
        return if (AI::inQueue("likeHuman"));
        return if (($config{'likeHumanInLockOnly'} > 0) && ($field{name} ne $config{lockMap}));

        debug " Starting Check of Chat Message.\n", "likeHuman";

        my ($packet, $args) = @_;
       
       
        my $likeMsgUsr = (($packet eq 'packet_selfChat') ? ($args->{user}) : ($args->{MsgUser}));


        my $likeMsg = (($packet eq 'packet_selfChat') ? ($args->{msg}) :  ($args->{Msg}));


        if ($config{'likeHumanStopAfter'}){

                debug " Checking if Message Received by User '$likeMsgUsr' are more than $config{'likeHumanStopAfter'}.\n", "likeHuman";
                       
                debug " Received are '$totalcount{$likeMsgUsr}'.\n", "likeHuman";

                if ($totalcount{$likeMsgUsr} > $config{'likeHumanStopAfter'}) {
                        if ($config{'likeHumanRealIgnoreOn'} == 1) {
                                Commands::cmdIgnore "ignore","1 $likeMsgUsr";
                        }
                        return;
                };
                       
                $totalcount{$likeMsgUsr}++;
        }

        if ($config{'likeHumanIgnore'}){

                debug " Checking if User '$likeMsgUsr' should be ignored.\n", "likeHuman";
               
                my $ignorel;

                $ignorel = $config{'likeHumanIgnore'};
                @ignorelist = split(/\s*;+\s*/, $ignorel);

                for (my $ii = 0; $ii < @ignorelist; $ii++) {
              next unless defined $ignorelist[$ii];
          if (match($ignorelist[$ii],$likeMsgUsr)){
                                debug " Match Found ['$ignorelist[$ii]'] vs. ['$likeMsgUsr'] - Ignoring.\n", "likeHuman";
                                if ($config{'likeHumanRealIgnoreOn'} == 1) {
                                        Commands::cmdIgnore "ignore","1 $likeMsgUsr";
                                }
                                return;
                        };
                }

        }

        for (my $i = 0; (exists $config{$prefix.$i}); $i++) {

                debug " Checking for likeHuman Block '$i'.\n", "likeHuman";

                debug " Checking if it is not our own Message.\n", "likeHuman";

                return if ($likeMsgUsr eq $char->{name});

                debug " Checking if Chat was ended with User '$likeMsgUsr'.\n", "likeHuman";

                return if ($chatended{$likeMsgUsr} == 1);

                $questionlist = $config{$prefix .$i. "_questions"};
                $answerlist = $config{$prefix .$i. "_answers"};
                @questions = split(/\s*;+\s*/, $questionlist);
                @answers = split(/\s*;+\s*/, $answerlist);
                $answer = $answers[rand(@answers)];
                $endingslist = $config{$prefix .$i. "_endings"};
                @endings = split(/\s*;+\s*/, $endingslist);

                debug " Values are:\nQuestions '$questionlist'\nAnswers '$answerlist'\nEndings '$endingslist'.\nRandom Answer '$answer'.\n", "likeHuman";

                my $type;

                debug " Checking Message Channel.($packet)\n", "likeHuman";

                if (($packet eq 'packet_pubMsg') && $config{$prefix.$i."_onPub"}) {

                        debug " Public Channel Detected.\n", "likeHuman";

                        $sanswer=likeCheckMsg($likeMsgUsr,$likeMsg,$i);
                        $type = "c";

                        if ($config{$prefix.$i."_distance"}) {

                                debug " Checking distance.\n", "likeHuman";
                                my $actor;
                                if ($args->{pubID}) {
                                        if ((substr($Settings::VERSION, 0, 3) >= 1.9) && (substr($Settings::VERSION, 4) >= 1)){
                                                $actor = $Globals::playersList->getByID($args->{pubID});       
                                        } else {
                                                $actor = $Globals::players{$args->{pubID}};
                                        }
                                        $sanswer = 0 if (distance($char->{pos_to},$actor->{pos_to}) > $config{$prefix.$i."_distance"});
                                }
                        }
                }
                elsif (($packet eq 'packet_selfChat') && $config{$prefix.$i."_onSystem"}) {

                        debug " System Channel Detected.\n", "likeHuman";

                        if ($likeMsg =~/:/) {
                                ($likeMsgUsr, $likeMsg) = $likeMsg =~ /(.*?).:.(.*)/;
                        }
                        else {
                                $likeMsgUsr="Server";
                        }
                        $sanswer=likeCheckMsg($likeMsgUsr,$likeMsg,$i);

                        $type = "c";

                }
                elsif (($packet eq 'packet_guildMsg') && $config{$prefix.$i."_onGuild"}) {

                        debug " Guild Channel Detected.\n", "likeHuman";

                        $sanswer=likeCheckMsg($likeMsgUsr,$likeMsg,$i);

                        $type = "g";

                }
                elsif (($packet eq 'packet_partyMsg')&& $config{$prefix.$i."_onParty"}) {

                        debug " Party Channel Detected.\n", "likeHuman";

                        $sanswer=likeCheckMsg($likeMsgUsr,$likeMsg,$i);
                       
                        $type = "p";

                }
                elsif (($packet eq 'packet_privMsg')&& $config{$prefix.$i."_onPM"}) {

                        debug " Private Channel Detected.\n", "likeHuman";

                        $sanswer=likeCheckMsg($likeMsgUsr,$likeMsg,$i);   

                        $type = "pm";
                }

                next if (!$sanswer);

                # exit if the config option is not enabled
                next if (!$type);

                # exit if we don't have any reply
                next if (!$answer);
                       
                ## COPIED FROM processChatResponse, ChatQueue.pm
                # Calculate a small delay (to simulate typing)
                # The average typing speed is 65 words per minute.
                # The average length of a word used by RO players is 4.25 characters (yes I measured it).
                # So the average user types 65 * 4.25 = 276.25 charcters per minute, or
                # 276.25 / 60 = 4.6042 characters per second
                # We also add a random delay of 0.5-1.5 seconds.
                my @words = split /\s+/, $answer;
                my $average;
                foreach my $word (@words) {
                        $average += length($word);
                }
                $average /= (scalar @words);
                my $typeSpeed = 65 * $average / 60;
       
                my $likeArgs;
                $likeArgs->{timeout} = (0.5 + rand(1)) + (length($answer) / $typeSpeed);

                debug " Timeout will be '$likeArgs->{timeout}'.\n", "likeHuman";

                $likeArgs->{time} = time;
                $likeArgs->{stage} = "start";
                $likeArgs->{reply} = $answer;
                $likeArgs->{prefix} = $prefix.$i;
                $likeArgs->{type} = $type;
                $likeArgs->{privMsgUser}= $likeMsgUsr;
                if ((AI::action ne 'likeHuman') && (main::checkSelfCondition($prefix))) {
                        AI::queue("likeHuman", $likeArgs);
                       
                        debug " Putting response in Queue.\n", "likeHuman";
                        message "likeHuman Block '$i' - Responding '$likeArgs->{reply}' to '$likeArgs->{privMsgUser}' in '$likeArgs->{timeout}' seconds.\n", "likeHuman" if ($config{'likeHumanConsole'});

                }
                       
                $sanswer = 0;
        }
}

sub AI_post {
        if (AI::action eq 'likeHuman') {
                my $args = AI::args;
                if ($args->{stage} eq 'end') {
                        AI::dequeue;

                        debug " Removing response from Queue.\n", "likeHuman";

                } elsif ($args->{stage} eq 'start') {
                        $args->{stage} = 'message' if (main::timeOut($args->{time}, $args->{timeout}));

                        debug " Executing response in Queue.\n", "likeHuman";

                } elsif ($args->{stage} eq 'message') {

                        debug " Sending response.\n", "likeHuman";

                        if ($args->{type} ne 'pm'){
                                sendMessage($messageSender, $args->{type}, $args->{reply}, undef);
                        }
                        else {
                                sendMessage($messageSender, $args->{type}, $args->{reply}, $args->{privMsgUser});
                        }

                        $args->{stage} = 'end';
                }
        }
}
sub match
{
        my ($pattern,$subject) = @_;
       
        if (my ($re, $ci) = $pattern =~ /^\/(.+?)\/(i?)$/)
        {       
                if (($ci && $subject =~ /$re/i) || (!$ci && $subject =~ /$re/))
                {
                        return 1;
                }
        }
        elsif ($subject eq $pattern)
        {
                return 1;
        }
        return 0;
}

sub likeCheckMsg
{
        my ($likeMsgUsr,$likeMsg,$i) = @_;
        my $ssanswer=$sanswer;

        debug " Messages previously received by '$likeMsgUsr' are $chatcount{$likeMsgUsr . '_' .$i}.\n", "likeHuman";
        debug "Usr:$likeMsgUsr Msg:$likeMsg\n", "likehuman";

        if ($config{$prefix . $i . "_chatCount"}) {
                for (my $ii = 0; $ii < @questions; $ii++) {
          next unless defined $questions[$ii];
                      if (match($questions[$ii],$likeMsg)){

                                debug " Match Found ['$questions[$ii]'] vs. ['$likeMsg'] - Responding '$answer'.\n", "likeHuman";

                                $chatcount{$likeMsgUsr . "_" .$i}++;

                                $ssanswer = 1;
                        };
                }
                if (!(Utils::inRange($chatcount{$likeMsgUsr . "_" .$i}, $config{$prefix . $i . "_chatCount"})) && ($ssanswer == 1)) {
                        if ($config{$prefix .$i. "_endings"}) {
                                $answer = $endings[rand(@endings)];
                                $chatended{$likeMsgUsr} = 1;
                                if ($config{'likeHumanRealIgnoreOn'} == 1) {
                                        Commands::cmdIgnore "ignore","1 $likeMsgUsr";
                                }
                        } else  {
                                $ssanswer = 0;
                        }

                        debug " ChatCount not in Range [$chatcount{$likeMsgUsr . '_' .$i} : $config{$prefix . $i . '_chatCount'}] - Ending Chat.\nResponding '$answer'.\n", "likeHuman";
                        message "likeHuman Block '$i' - Not Responding to '$likeMsgUsr' Cause ChatCount = $chatcount{$likeMsgUsr . '_' .$i}.\n", "likeHuman" if ($config{'likeHumanConsole'});

                }
        }else  {
                for (my $ii = 0; $ii < @questions; $ii++) {
                        next unless defined $questions[$ii];
              if (match($questions[$ii],$likeMsg)){
                                $ssanswer = 1;

                                debug " Match Found ['$questions[$ii]'] vs. ['$likeMsg'] - Responding '$answer'.\n", "likeHuman";

                                $chatcount{$likeMsgUsr . "_" .$i}++;

                        };
                }
        }
        return $ssanswer;
}


return 1;