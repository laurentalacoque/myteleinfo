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

if (($#ARGV != -1) and ($#ARGV != 1)){
    print STDERR "Usage : $0 [-c <config_file> | --config-file <config_file>]\n"; 
    exit(1);
}

if (($ARGV[0] eq "-c") or ($ARGV[0] eq "--config-file")){
    $config_file = $ARGV[1];
}

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
        print "Updating $key\n";
        $serial{$key} = $$config{"serial-devices"}{$key};
    }
}

my %tags;
foreach my $key(keys $$config{"tags"}){
    print "adding tag $key\n";
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

#TODO Add jeedom config parsing here

print "config:\n";
print Dumper(\%tags);


###############################################
#   Start the polling loop
###############################################
print "opening port ".$serial{"path"}."\n";
my $port=Device::SerialPort->new($serial{"path"}) or die ("Unable to open serial port\n");
$port->databits($serial{"databits"});
$port->baudrate($serial{"baudrate"});
$port->parity($serial{"parity"});
$port->stopbits($serial{"stopbits"});

print "Starting polling :)\n";


$port->are_match(keys %tags);
print "watching for ".join(":",keys %tags)."\n";
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
            print "$pattern=$current_value\n";
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
            }
        }
#    } while ($match and $match ne "");
}

sub update{
    my($tag,$value) = @_;
    print "updating $tag with value $value\n";
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
