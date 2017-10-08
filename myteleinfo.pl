use strict;
# used to get infos from serial port 
# missing? : sudo apt-get install libdevice-serialport-perl
use Device::SerialPort qw( :PARAM :STAT);
# read config file
# missing? : sudo apt-get install libjson-perl
use JSON;
use Time::HiRes qw (usleep);
# debug
# missing? : sudo apt-get install libdata-dumper-perl
use Data::Dumper;

###############################################
#   Parse args                                #
###############################################
my $config_file="config.json";
my $log_file="/dev/null";
if (($ARGV[0] eq "-c") or ($ARGV[0] eq "--config-file")){
    $config_file = $ARGV[1];
}

if (($ARGV[2] eq "-l") or ($ARGV[2] eq "--log-file")){
    $log_file = $ARGV[3];
}

open(LOG,">",$log_file);


###############################################
#   Read config file                          #
###############################################

open(CFG,$config_file) or die ("Unable to open $config_file : $!\n");
my $config = decode_json join("",<CFG>);
close(CFG);

my %serial=(
    path     => "/dev/ttyUSB0",
    baudrate => 1200,
    parity   => "even",
    stopbits => 1,
    databits => 7
);

foreach my $key(keys %serial){
    if (defined($$config{"serial-devices"}) and defined($$config{"serial-devices"}{$key})){
        print LOG "Updating $key\n";
        $serial{$key} = $$config{"serial-devices"}{$key};
    }
}

my %tags;
foreach my $key(keys $$config{"tags"}){
    print LOG "adding tag $key\n";
    $tags{$key}{"value"}=0;
    if (defined($$config{"tags"}{$key}{"precision"})){
        if ($$config{$key}{"tags"}{"precision" eq "always"}){
            $tags{$key}{"precision"}=0;
        } else {
            $tags{$key}{"precision"}=int($$config{"tags"}{$key}{"precision"});
        }
    }
    if (defined($$config{"tags"}{$key}{"jeedom-id"})){
            $tags{$key}{"jeedom-id"}=int($$config{"tags"}{$key}{"jeedom-id"});
    }
}

my $day_stat_jeedom_id = $$config{"stats"}{"daily"};
my $hour_stat_jeedom_id = $$config{"stats"}{"hourly"};

#TODO Add jeedom config parsing here
my $jeedom_update_url="";
if ( defined($$config{"jeedom-target"}) and
    defined($$config{"jeedom-target"}{"host"}) and
    defined($$config{"jeedom-target"}{"port"}) and
    defined($$config{"jeedom-target"}{"key"})){
    my $host = $$config{"jeedom-target"}{"host"};
    my $port = $$config{"jeedom-target"}{"port"};
    my $key  = $$config{"jeedom-target"}{"key"};
    $jeedom_update_url="http://$host:$port/core/api/jeeApi.php?api=$key&type=virtual";
}

###############################################
#   Start the polling loop
###############################################
my @ts=localtime(time);
my $today=$ts[3];
my $today_Wh=0;
my $hour =$ts[2];
my $hour_Wh=0;
my $Wh_hp=0;
my $Wh_hc=0;

print LOG "opening port ".$serial{"path"}."\n";
my $port=Device::SerialPort->new($serial{"path"}) or die ("Unable to open serial port\n");
$port->databits($serial{"databits"});
$port->baudrate($serial{"baudrate"});
$port->parity($serial{"parity"});
$port->stopbits($serial{"stopbits"});

print LOG "Starting polling :)\n";


$port->are_match(keys %tags);
#print "watching for ".join(":",keys %tags)."\n";
$port->lookclear();
my $match;
while (1){
    my $gotit = "";
    until ("" ne $gotit) {
        $gotit = $port->streamline;       # poll until data ready
        die "Aborted without match\n" unless (defined $gotit);
        usleep(500000);                          # polling sample time
    }
#    do {
        my ($after,$pattern,$instead);
        ($match, $after, $pattern, $instead) = $port->lastlook;
        # input that MATCHED, input AFTER the match, PATTERN that matched
        if ($after =~ m/ (\S+) (.)\r/) {
            my $trame="$pattern $1 $2";
            my $current_value=$1;
            my $forcrc="$pattern $1";
            my $crc=$2;
            if (check_crc($forcrc,$crc)){
                #print "$pattern=$current_value\n";
                if (not defined($tags{$pattern}{"precision"})){
                    #update if value changes
                    if (not($current_value eq $tags{$pattern}{value})) { 
                        $tags{$pattern}{value}=$current_value;
                        update($pattern,$current_value);
                    }
                } else {
                    my $precision = $tags{$pattern}{precision};
                    if ($precision > 0 ){
                        if (int($current_value / $precision ) != int($tags{$pattern}{value} / $precision)){
                            $tags{$pattern}{value}=$current_value;
                            update($pattern,$current_value);
                        }
                    }
                    else {
                        #precision = 0 => always update
                        update($pattern,$current_value);
                    }
                }     
                #update Wh_hp and Wh_hc
                if ($pattern eq "HCHP") {
                    $Wh_hp = $current_value;
                }
                if ($pattern eq "HCHC") {
                    $Wh_hc = $current_value;
                }
                #update stats
                @ts=localtime(time);
                if ($day_stat_jeedom_id and $ts[3] != $today){
                    #do something once per day
                    if ($today_Wh != 0) {
                        update_stats("daily",$Wh_hp+$Wh_hc-$today_Wh,$day_stat_jeedom_id);
                    }
                    $today_Wh = $Wh_hp + $Wh_hc;
                    $today = $ts[3];    
                }
                if ($hour_stat_jeedom_id and $ts[2] != $hour){
                    #do something once per hour
                    if ($hour_Wh != 0) {
                        update_stats("hourly",$Wh_hp+$Wh_hc-$hour_Wh,$hour_stat_jeedom_id);
                    }
                    $hour_Wh = $Wh_hp + $Wh_hc;
                    $hour = $ts[2];
                }
            }
        }
#    } while ($match and $match ne "");
}

sub update{
    my($tag,$value) = @_;
    my $jeedom_id = $tags{$tag}{"jeedom-id"};
    update_stats($tag,$value,$jeedom_id);
}
sub update_stats{
    my($tag,$value,$id) = @_;
    print LOG "[$tag] $value -> $id\n";
    if ($tag eq "PTEC"){
        if($value eq "HP..") {$value=0;}
        else {$value=1;}
    }
    if ($jeedom_update_url and defined($id) and defined($value) ){
        my $action=$jeedom_update_url."&id=$id&value=$value";
        print LOG `/usr/bin/curl -s '$action'`;
    }
}

sub check_crc{
    my($forcrc,$crc)=@_;
    my @vals=unpack "C*",$forcrc;
    my $sum=0;
    foreach my $val(@vals){ $sum += $val; }
    $sum &= 0x3F;
    $sum += 0x20;

    #print "crc: $crc (".ord($crc).") calculé: ".chr($sum)." ($sum)\n";
    if ($crc eq chr($sum)) {return 1;}
    #else {
    #print "[$forcrc] (".join (':',@vals) .") ";
    #print "crc: $crc (".ord($crc).") calculé: ".chr($sum)." ($sum)\n";
    #}
    return 0;
}
