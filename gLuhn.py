#!/usr/bin/python

## gLuhn.py version 0.7 - Check/Generate PAN based on the Luhn algorithm (c)gfragkos 2013  ##
## You may modify, reuse and distribute the code freely as long as it is referenced back   ##
## to the author using the following line: ..based on gLuhn.py by @drgfragkos              ##

import sys
import numpy
import re


def LuhnChk(card_number):
    if (IIN_Ranges(card_number)!=True):
	return
	
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


def IIN_Ranges(card_number):
    IIN_tuple_ranges = ('4','51','52','53','54','55','36','37','38','6011','65','35','34','37')
    
    for iin in IIN_tuple_ranges:
	if card_number[0:len(iin)] == str(iin):
		return True
		break
    return False
	
    

def GenDigits(card_number):
    if card_number.count("?") > 0 and len(card_number) <= 16:
	possibilities = numpy.uint64(10**card_number.count("?"))  ## Precalculate the number of combinations
	print "Attempting to generate " + str(possibilities) + " PAN combinations for: " + str(card_number)
	counter = 0

	PANasList = list(card_number)     ## Convert the PAN number into a List

	L = []                            ## A list with the indexes of the ? characters as found in given PAN
	for m in re.finditer('\?', card_number):
		L.append(m.start())
		
	TotalPANs = 0                     ## Count the number of valid generated PAN combinations
	STR_LIST = []                     ## A list for the generated combinations of digits
	while (counter < possibilities):  
		if len(str(counter)) < card_number.count("?") + 1:
			m = card_number.count("?") - len(str(counter))
			STR = "0" * m + str(counter)
			
		else:
			STR = str(counter)
		
		STR_LIST = STR
		counter = counter + 1
		
		c = 0
		for item in L:
			c = c + 1	
			PANasList[item]=STR_LIST[c-1]

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
	print "gLuhn.py v0.7 - Check/Generate PAN based on Luhn algorithm (c)gfragkos 2013 "
	print ""
        print "usage:", sys.argv[0],"[PAN]"
	print "      PAN     Given any Primary Account Number (PAN), the application will  "
        print "              check if it is valid by using the Luhn algorithm.             "
        print "              If the PAN contains any number of question mark (?) characters"
	print "              e.g.: 12345555?23412?4, all valid combinations for that PAN   "
        print "              will be generated.                                            " 
        exit(0);

    if len(sys.argv[1]) <= 16 and sys.argv[1].isdigit():      ## Validate a PAN with Luhn
	if LuhnChk(sys.argv[1]):
		print "[+] Valid PAN ",LuhnChk(sys.argv[1])
	else:
		print "[-] Invalid PAN ",LuhnChk(sys.argv[1])

    else:                                                     ## Generate PANs 
	if len(sys.argv[1]) <= 16 and re.match("^[0-9\?]*$",sys.argv[1]): 
		print GenDigits(sys.argv[1].strip())
        		



