#!/usr/bin/python
import sys
import numpy
import re


def LuhnChk(card_number):
    sum = 0
    numLength = len(card_number)
    oddeven = numLength & 1
    for count in range(0, numLength):
        digit = int(card_number[count])
        if not (( count & 1 ) ^ oddeven ):
            digit = digit * 2
        if digit > 9:
            digit = digit - 9
        sum = sum + digit
    return ( (sum % 10) == 0 )


def GenDigits(card_number):
    if card_number.count("?") > 0 and len(card_number) <= 16:
	possibilities = numpy.uint64(10**card_number.count("?"))
	print "Attempting to generate " + str(possibilities) + " PAN combinations for: " + str(card_number)
	##counter = numpy.uint64(0) ## declaring a HUGE counter: Unsigned integer (0 to 18446744073709551615)
	counter = 0

	PANasList = list(card_number) # Make the PAN number a List

	L = []
	for m in re.finditer('\?', card_number):
		L.append(m.start())
	##print L ## A list with the indexes of the ? characters as found in given PAN
		
	TotalPANs = 0 ##To count how many of the generated PAN combinations are actually valid with Luhn
	STR_LIST = [] ##A list for the generated combinations of digits
	while (counter < possibilities):
		##print counter,"\n"
		if len(str(counter)) < card_number.count("?") + 1:
			m = card_number.count("?") - len(str(counter))
			##print  "0" * m + str(counter)
			STR = "0" * m + str(counter)
			
		else:
			##print str(counter)
			STR = str(counter)
		
		STR_LIST = STR
		counter = counter + 1
		
		c = 0
		for item in L:
			c = c + 1	
			PANasList[item]=STR_LIST[c-1]

		##print "".join(PANasList) ##Debug. Output generated PAN
		tempPAN = "".join(PANasList)
		if LuhnChk(tempPAN):
			print "[+] Valid PAN ",tempPAN
			TotalPANs = TotalPANs + 1			
			
	return "\nTotal valid PAN generated: " + str(TotalPANs)


#############################################################################################
## Main
##

if __name__ == "__main__":
    if len(sys.argv) != 2:
	print "gLuhn.py v0.7 - Check/Generate PAN based on Luhn algorithm (c)gfragkos 2013  "
	print ""
        print "usage:", sys.argv[0],"[PAN]"
	print "      PAN       Given any Primary Account Number (PAN), the application will "
        print "                check if is valid by using the Luhn algorithm.               "
        print "                If the PAN contains any number of questionmark (?) characters"
	print "                e.g.: 12345555?23412?4, all valid combinations for that PAN  "
        print "                will be generated.                                           " 
        exit(0);

    if len(sys.argv[1]) <= 16 and sys.argv[1].isdigit():  ## Validate a PAN with Luhn
	if LuhnChk(sys.argv[1]):
		print "[+] Valid PAN ",LuhnChk(sys.argv[1])
	else:
		print "[-] Invalid PAN ",LuhnChk(sys.argv[1])

    else:  ## Generate PANs 
	if len(sys.argv[1]) <= 16 and re.match("^[0-9\?]*$",sys.argv[1]): 
	##result = re.match(pattern, string)
		print GenDigits(sys.argv[1].strip())
        		



