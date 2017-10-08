# myteleinfo: a deported sense node for jeedom
This projects aims at
- lowering jeedom system charge
- solving the wires problem when the jeedom host is not in the same room as the ErDF terminal

## How it works
This consists of:
1. A daemon script and its configuration that must be run on the raspberry-pi to which the ErDF modem is connected
1. A (pre-created and pre-populated) jeedom "virtual" that will get all data.

Data are updated through jeedom web interface :

`curl 'http://ip_of_jeedom:port/core/api/jeeApi.php?api=`**YOURAPIKEY**`&type=virtual&id=`**YOURVIRTUALCMDID**`&value=MODEMREADVALUE'`

## Installing

* create a new virtual in jeedom, add as many "infos" as you want and keep track of their respective id
* copy myteleinfo.pl somewhere on your system
* copy and edit the configuration file to suit your needs
* add a line in your raspberry /etc/rc.local file such as
    `/usr/bin/perl /path_to_my_daemon/myteleinfo.pl -c /path_to_cfg/myconfig.json -l /var/log/myteleinfo.log`
* reboot the raspberry and check if the script has started ( ps aux |grep myteleinfo ) and check the log

## Configuration file

Here's a commented version of the configuration file (remove comments to get a valid JSON file)
```javascript
  {
    // Serial link configuration, see perl Device::SerialDevice module
     "serial-device": {
         "path": "/dev/ttyUSB0",
         "baudrate": 1200,
         "parity": "even",
         "databits": 7,
         "stopbits": 1
     },
     // Address, port and key of the target jeedom device
     "jeedom-target":{
         "host" : "192.168.0.200",
         "port" : "80",
         //replace the following with your APIKEY
         // the apikey can be found on your virtual equipement main page
         // there's an "URL de retour" with parameter apikey=<yourapikeyhere>&type=virtual
         "key"  : "JKyUOOY8cn9WZjg6Ky0GxYn2gR1aWL3m"
     },
     // list of what you want to track
     "tags": {
         // keys should exactly be the teleinformation tags
         "HCHC" : {
             // the optionnal precision parameter lets you slow-down the production of informations
             // will only send a new value every 50 Wh
             "precision" : 50,
             // This jeedom-id correspond to the command id of the virtual information
             "jeedom-id" : 144
         },
         "HCHP" : {
             "precision" : 50,
             "jeedom-id" : 165
         },
         "PAPP" : {
             "precision" : 100,
             "jeedom-id" : 153
         },
         "PTEC": {
             // omitting precision parameter defaults to : send information only if it has changed
             "jeedom-id" : 434
         },
         "ADPS": {
             // precision always means that this information will be sent even if it hasn't changed
             "precision" : "always",
             "jeedom-id" : 435
         }
     },
     // additionnaly to standard messages, you can get hourly and daily power consumption stats.
     // just add some target ids to get hourly Wh consumption and/or daily power consumption
     "stats":{
         "hourly":{
             "jeedom-id": 4
         },
         "daily":{
             "jeedom-id": 5
         }
     }
 }
```
