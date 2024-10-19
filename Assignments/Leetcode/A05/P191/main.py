class Solution:
    def hammingWeight(self, n: int) -> int:
        binary = bin(n)
        counter = 0

        for c in binary:
            if c == '1':  
                counter += 1
        
        return counter
        
