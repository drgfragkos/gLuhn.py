# gLuhn.py

You may modify, reuse and distribute the code freely as long as it is referenced back
to the author using the following line: ..based on gLuhn.py by @drgfragkos

gLuhn.py v0.7 - Check/Generate PAN based on Luhn algorithm (c)gfragkos 2013
gLuhn.py v0.8 - Check/Generate PAN based on Luhn algorithm, validate IIN (c)gfragkos 2020

usage: gLuhn.py [PAN]
              Given any Primary Account Number (PAN), the application checks if
              it is valid by checking against the Luhn algorithm. (No IIN check)

              If the PAN contains any number of question mark (?) characters
              e.g.: 12345555?23412?4, all valid combinations for that PAN are
              generated, while excluding any PAN that doesn't belong to a valid
              Issuer Identification Number (IIN)

Note:
I couldn't find a tool capable of generating all possible combinations of valid card 
numbers (PAN) while specific digits in the PAN are known already. The tool can be used 
to validate a single PAN or it can generate all valid combinations for a partially 
known PAN. This tool is meant to be useful for:
  a) data discovery
  b) digital forensics investigations
  c) OSINT


Examples:
For example, if you give a valid PAN, the output will be: 
$ python gLuhn.py 1111222233334444
[+] Valid PAN  True

If you provide a potential PAN where one or more specific digits are not known (as you need
to represent them with question marks), the output will be:

$ python gLuhn.py 111122?233334444
Attempting to generate 10 PAN combinations for: 111122?233334444
[+] Valid PAN  1111222233334444

Total valid PAN generated: 1

$ python gLuhn.py 5126877700?00?03
Attempting to generate 100 PAN combinations for: 5126877700?00?03
[+] Valid PAN  5126877700000903
[+] Valid PAN  5126877700100703
[+] Valid PAN  5126877700200503
[+] Valid PAN  5126877700300303
[+] Valid PAN  5126877700400103
[+] Valid PAN  5126877700500803
[+] Valid PAN  5126877700600603
[+] Valid PAN  5126877700700403
[+] Valid PAN  5126877700800203
[+] Valid PAN  5126877700900003

Total valid PAN generated: 10


To Do:
Include a command line option to use the IIN check for the simple PAN validation.


Download:
$ git clone https://github.com/drgfragkos/gLuhn.py.git


Version:
0.8.0 : 2020/05/07 - GitHub update to include IIN checks
0.7.0 : 2015/05/15 - Released on GitHub. 
0.6.0 : 2013/02/28 - Initial version not publicly released.


Dependencies:
You need to have 'numpy' installed.
In case you need to check your Python version: $ python --version
Check if you have numpy: $ apt-cache policy python-numpy
Install numpy: $ apt-get install python-numpy


##                                                                                        ##
##                                                                                        ##
############################################################################################



