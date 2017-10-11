    #include <stdio.h>   /* Standard input/output definitions */
    #include <string.h>  /* String function definitions */
    #include <unistd.h>  /* UNIX standard function definitions */
    #include <fcntl.h>   /* File control definitions */
    #include <errno.h>   /* Error number definitions */
    #include <termios.h> /* POSIX terminal control definitions */

#define INTER_READ_SLEEP_US 	(100000)
#define MAX_EMPTY_READS 	(100)
#define BUFFER_SIZE		(1024)

    /* Most of this code is taken from https://www.cmrr.umn.edu/~strupp/serial.html#2_5_2 */

    struct termios options;

    /*
     * 'open_port(path)' - Open serial port.
     *
     * Returns the file descriptor on success or -1 on error.
     */

    int
    open_port(char* path)
    {
      int fd; /* File descriptor for the port */


      fd = open(path, O_RDWR | O_NOCTTY | O_NDELAY);
      if (fd == -1)
      {
       /*
        * Could not open the port.
        */
        perror("open_port: Unable to open file - ");
      }
      else
      	/* Set nonblocking IO */
        fcntl(fd, F_SETFL, FNDELAY);

      return (fd);
    }

    /*
     * Set options for the serial interface
     */
    int set_options(int fd){
    	//Get current options
	if (tcgetattr(fd,&options) == -1)
		perror("tcgetattr:");
	//Set Baud Rates
	if (cfsetispeed(&options,B1200) ==-1)
		perror("cfsetispeed:");
	if (cfsetospeed(&options,B1200) ==-1)
		perror("cfsetospeed:");
	//Enable receiver and set local flag
	options.c_cflag |= (CLOCAL | CREAD);
	//Set parity to 7E1
	options.c_cflag |= PARENB;
	options.c_cflag &= ~PARODD;
	options.c_cflag &= ~CSTOPB;
	options.c_cflag &= ~CSIZE;
	options.c_cflag |= CS7;
	//Disable hardware control
	options.c_cflag &= ~CRTSCTS;

	//set receive mode to canonical input
	options.c_lflag |= (ICANON);
	// disable echo
	options.c_lflag &= ~(ECHO | ECHOE);

	//Handle input parity
	options.c_iflag |= (INPCK | ISTRIP);

	//Handshaking
	options.c_iflag |= (IXON | IXOFF | IXANY);

	if(tcsetattr(fd,TCSANOW,&options) == -1)
		perror("tcsetattr:");

	return (fd);
    }

/* check the erdf crc of a field such as
 * "IINST 001 I" where the final 'I' is the crc code calculated as the
 * sum of all the ascii characters "IINST 001" truncated to 6 bits + 0x20
 */
int check_crc(char* field, int field_length){
	int sum=0;
	int i;
	for (i=0; i<field_length -2; i++) sum += field[i];
	sum &= 0x3F;
	sum += 0x20;

	if (field[field_length-1] == sum) return 1;
	return 0;
}

/* look for a \x0A<Field>\x0D delimited field
 * start at *start and no longer that buffer_size
 * return 0 if the field has been found and 0 if not
 * if a field has been found, then *start is the offset of \x0A and 
 * *end is the offset of the \x0D
 */
int look_for_field(char* buffer, int buffer_size,int *start, int *end){
	int i=*start;
	for (i=*start; i<buffer_size; i++){
		if (buffer[i] == 0x0A) {
			*start=i;
			break;
		}
	}
	// if we override, then let's return now
	if (i==buffer_size) return 0;
	// we didn't override, let's find the end char
	for (i=*start; i<buffer_size; i++){
		if (buffer[i] == 0x0D) {
			*end=i;
			return 1;
		}
	}
	return 0;
}
/*
 * handle data just acquired in buffer
 * once processed, everything between the end of handled data and count
 * will be moved to the start of the buffer
 * returns the number of unhandled chars
 */
int handle_data(char* buffer,int count){
	int i,len;
	int start,end;
	// should look for data here
	// DEBUG
	char printme[BUFFER_SIZE];
	snprintf(printme,BUFFER_SIZE,"%s",buffer);
	len=strlen(printme);
	for(i=0; i< len; i++){
		if (printme[i]== 0x02) printme[i] = '{';
		if (printme[i]== 0x03) printme[i] = '}';
		if (printme[i]== 0x0A) printme[i] = '\\';
		if (printme[i]== 0x0D) printme[i] = '/';
	}
	printf("[%s\n]",printme);
	// DEBUG
	
	//find fields
	start=0;
	end=0;
	while (look_for_field(buffer,count,&start,&end)){
		strncpy(printme,buffer+start+1,end-start-2);
		printf("\t[[%s]]\n",printme);
		start=end+1;
	}
}

int main (void){
	char buffer[BUFFER_SIZE];
	//this will be used to start acquisition just after unhandled data 
	int  charoffset=0;
	char *path="/dev/ttyUSB0";
	ssize_t count;
	int empty_count=0;
	int fd=open_port(path);
	if (fd == -1) { return 1; }
	fd=set_options(fd);

	while(1){
		count=read(fd,buffer+charoffset,BUFFER_SIZE-1-charoffset);	
		if (0 == count){
			//nothing for now, just wait
			empty_count++;
		} else if (count < 0) {
			perror("read error:");
			close(fd);
			return 2;
		} else {
			empty_count=0;
			charoffset = handle_data(buffer,count);
		}
		if (empty_count > MAX_EMPTY_READS){
			fprintf(stderr,"Are you dead? no frame received in %.1f ms, reopening port\n",((INTER_READ_SLEEP_US * 1.0)*MAX_EMPTY_READS)/1000.0);
			close(fd);
			fd=open_port(path);
			if (fd == -1) { return 1; }
			fd=set_options(fd);
		}
		usleep(INTER_READ_SLEEP_US);
	}
	
}


