class Solution:
    def isPalindrome(self, x: int) -> bool:
        reversed = 0
        num = x
        while x > 0:
            last_digit = x % 10
            reversed = reversed * 10 + last_digit
            x = x // 10
        
        if num == reversed:
            return True
        else:
            return False

        
