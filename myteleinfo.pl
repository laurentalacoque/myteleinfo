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
# use Data::Dumper;
use Getopt::Long;
use Pod::Usage;

# TIMEOUT between two successful reads
my $MAX_WAIT_BETWEEN_READ = 30;


###############################################
#   Parse args                                #
###############################################
my $config_file="";
my $log_file="";
my $help="";
my $LOG=*STDOUT;

GetOptions("help",\$help,"config-file=s",\$config_file,"log-file=s",\$log_file) or pod2usage(-verbose => 1, -exitval => 1);

if ($help) {
    pod2usage(-verbose => 1, -exitval => 0);
}

if ($config_file eq "") { $config_file="config.json";}
if (not ($log_file eq "")) {
    open($LOG,">",$log_file) or die ("Unable to open $log_file : $!\n");
}


###############################################
#   Read config file                          #
###############################################
#TODO use Config::Simple instead
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
        print $LOG "Updating $key\n";
        $serial{$key} = $$config{"serial-devices"}{$key};
    }
}

my %tags;
foreach my $key(keys $$config{"tags"}){
    print $LOG "adding tag $key\n";
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

my $day_stat_jeedom_id = $$config{"stats"}{"daily"}{"jeedom-id"};
my $hour_stat_jeedom_id = $$config{"stats"}{"hourly"}{"jeedom-id"};

#jeedom host config
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
my $last_read_time=time;

print $LOG "opening port ".$serial{"path"}."\n";
my $port=Device::SerialPort->new($serial{"path"}) or die ("Unable to open serial port\n");
$port->databits($serial{"databits"});
$port->baudrate($serial{"baudrate"});
$port->parity($serial{"parity"});
$port->stopbits($serial{"stopbits"});
$port->stty_icanon(1);

print $LOG "Starting polling :)\n";

#Add wanted TAGS to the watchlist
#$port->are_match(keys %tags);
#$port->are_match('\n');
#$port->lookclear();

my $polls_per_data=0;
my $usleep_time =50000;
#Polling loop
while (1){
    # scan incoming data until we get a full line
    my $saw="";
    my $count=0;
    $polls_per_data = 0;
    while ($count == 0){
        $polls_per_data ++;
        ($count,$saw)=$port->read(255); # will read _up to_ 255 chars
        #if there was an error or we timedout, try to reopen the port
        if ( 
            ($count < 0) or
            (time - $last_read_time > $MAX_WAIT_BETWEEN_READ))
            { 
                reopen_serial_port(); 
                $last_read_time=time;
            }
        #sleep some time (a 11B message at 12000 bauds => 77ms)
        usleep($usleep_time);                         

    }
    # New data arrived
    #print $LOG "polls: $polls_per_data\n";
    if ($polls_per_data <= 2 and $usleep_time > 10000) { 
        #too slow
        $usleep_time -= 10000;
        #print "$polls_per_data polls => new usleep $usleep_time\n";
    } elsif ($polls_per_data > 5 and $usleep_time <1000000) {
        #too fast
        $usleep_time += 10000;
        #print "$polls_per_data polls => new usleep $usleep_time\n";
    }

    $polls_per_data = 0;
    
    if ($saw =~ m/(\S+) (\S+) (.)\r/) {
        #print $LOG "[$1 $2 $3]\n";
        my $pattern= $1;
        my $trame="$pattern $2 $3";
        my $current_value=$2;
        my $forcrc="$pattern $2";
        my $crc=$3;
        #skip tag if it's not registered
        next if (not(defined($tags{$pattern})));
        # we have a TAG VALUE CRC triplet, validate CRC
        if (check_crc($forcrc,$crc)){
            #CRC matches
            #print "CRC match\n";
            #Now check if config has a precision value associated to this tag
            if (not defined($tags{$pattern}{"precision"})){
                #No precision value => update when value changes
                if (not($current_value eq $tags{$pattern}{value})) { 
                    #current value is different from stored one => update
                    $tags{$pattern}{value}=$current_value;
                    update($pattern,$current_value);
                }
            } else {
                # precision config flag exists
                my $precision = $tags{$pattern}{precision};
                if ($precision > 0 ){
                   #precision > 0 means update only if values differ over precision
                   if (int($current_value / $precision ) != int($tags{$pattern}{value} / $precision)){
                       # They do differ, update them
                       $tags{$pattern}{value}=$current_value;
                       update($pattern,$current_value);
                   }
                } else {
                   #precision <= 0 => always update
                   update($pattern,$current_value);
                }

            } #precision config handling
            
            #keep track of hourly and daily stats
            #update Wh_hp and Wh_hc
            if ($pattern eq "HCHP") { $Wh_hp = $current_value; }
            if ($pattern eq "HCHC") { $Wh_hc = $current_value; }
            #update stats
            @ts=localtime(time);
            #daily stats
            if ($day_stat_jeedom_id and $ts[3] != $today){
                #do something once per day
                if ($today_Wh != 0) { update_stats("daily",$Wh_hp+$Wh_hc-$today_Wh,$day_stat_jeedom_id); }
                $today_Wh = $Wh_hp + $Wh_hc;
                $today = $ts[3];    
            }
            #hourly stats
            if ($hour_stat_jeedom_id and $ts[2] != $hour){
               #do something once per hour
               if ($hour_Wh != 0) { update_stats("hourly",$Wh_hp+$Wh_hc-$hour_Wh,$hour_stat_jeedom_id); }
               $hour_Wh = $Wh_hp + $Wh_hc;
               $hour = $ts[2];
            }
        } #crc check
        $last_read_time =time; # reset the watchdog
    } # match one tag
} # infinite loop

sub update{
    my($tag,$value) = @_;
    my $jeedom_id = $tags{$tag}{"jeedom-id"};
    update_stats($tag,$value,$jeedom_id);
}
sub update_stats{
    my($tag,$value,$id) = @_;
    printf $LOG "%02d:%02d:%02d [$tag:$id] $value\n",$ts[2],$ts[1],$ts[0];
    #TAG PTEC is a 4 chars value with 'HP..' or 'HC..'
    #we translate this to a boolean
    if ($tag eq "PTEC"){
        if($value eq "HP..") {$value=0;}
        else {$value=1;}
    }
    #If we have an update URL, get it
    if ($jeedom_update_url and defined($id) and defined($value) ){
        my $action=$jeedom_update_url."&id=$id&value=$value";
        print $LOG `/usr/bin/curl -s '$action'`;
    }
}

sub reopen_serial_port{
    #close port, wait 1 sec and try reopening it
    print $LOG "Reopening serial port\n";
    $port->close;
    $port=0;
    while (not $port){
        sleep(1);
        $port=Device::SerialPort->new($serial{"path"}) ;
        if ($port) {
            $port->databits($serial{"databits"});
            $port->baudrate($serial{"baudrate"});
            $port->parity($serial{"parity"});
            $port->stopbits($serial{"stopbits"});
            $port->stty_icanon(1);
        } else {
            print "Unable to open port, waiting 1sec\n";
        }
    }
}

sub check_crc{
    #crc is the sum of all characters from start of tag to end of value truncated to 6bits summed with 0x20
    my($forcrc,$crc)=@_;
    my @vals=unpack "C*",$forcrc;
    my $sum=0;
    foreach my $val(@vals){ $sum += $val; }
    $sum &= 0x3F;
    $sum += 0x20;
    #sum should be equal to embedded crc
    if ($crc eq chr($sum)) {return 1;}
    return 0;
}


__END__

=head1 NAME

B<myteleinfo> a ErDF teleinformation smart bouncer

=head1 SYNOPSIS

perl myteleinfo [options] 

=head1 OPTIONS

=over 8

=item B<-h | --help>

Print a brief help message and exits.

=item B<-c | --config-file> <config file>

Use <config file> instead of the default config.json

=item B<-l | --log-file> <log file>

Logs everything into <log file> instead of stdout

=back

=head1 DESCRIPTION

B<myteleinfo> will scan French energy provider ErDF power information and will send 
selected ones to a destination server address.
This is usefull to track power consumption using a home box like e.g. jeedom

=cut


