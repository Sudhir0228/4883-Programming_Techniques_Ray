class Solution:
    
    def isPalindrome(self, s: str) -> bool:
        word = ""
        reversedWord = ""
        for char in s:
            if char.isalnum():
                word += char

        reversedWord = word[::-1]
        reversedWord = reversedWord.lower()
        word = word.lower()
        
        
        if (word == reversedWord):
            return True
        else:
            return False
