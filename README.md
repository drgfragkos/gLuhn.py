# gLuhn.py

You may modify, reuse and distribute the code freely as long as it is referenced back
to the author using the following line: ..based on gLuhn.py by @drgfragkos

gLuhn.py v0.7 - Check/Generate PAN based on Luhn algorithm (c)gfragkos 2013  

usage: gLuhn.py [PAN]
Given any Primary Account Number (PAN), the application will check if it is valid by using
the Luhn algorithm. If the PAN contains any number of question mark (?) characters 
e.g.: 12345555?23412?4, all valid combinations for that PAN will be generated.

I couldn't find a tool capable of generating all possible combinations of valid card 
numbers (PAN) while specific digits in the PAN are known already. The tool can be used 
to validate a single PAN or it can generate all valid combinations for a partially 
known PAN. 


Examples:
For example, if you give a valid PAN, the outpu will be: 
python gLuhn.py 1111222233334444
[+] Valid PAN  True

If you give a potential PAN where one or more specific digits are not known (mark them 
with question marks) , the output will be:
python gLuhn.py 111122?233334444
Attempting to generate 10 PAN combinations for: 111122?233334444
[+] Valid PAN  1111222233334444

Total valid PAN generated: 1


To Do:
Include checks for IIN and BIN. This will result in knowing that the PAN 1111222233334444 
even even though the number validates the Luhn algorithm, it is not being used be the card
issuers. Thus, it is not a valid PAN and it will be excluded from the list of valid answers.


Download:
git clone https://github.com/drgfragkos/gLuhn.py.git


Version:
0.7.0 : 2015/05/15 - Released on GitHub. 
0.6.0 : 2013/02/28 - Initial version not publicly released.


Dependencies:
You need to have numpy installed.
In case you need to check your Python version: python --version
Check if you have numpy: apt-cache policy python-numpy
Install numpy: apt-get install python-numpy


##                                                                                        ##
##                                                                                        ##
############################################################################################



