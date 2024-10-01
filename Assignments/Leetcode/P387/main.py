class Solution:
    def firstUniqChar(self, word: str) -> int:
        count = {}
        for char in word:
            if char in count:
                count[char] +=1
            else:
                count[char] = 1
        
        for i in range(len(word)):
            if count[word[i]] == 1:
                return i
        
        return -1


        
  
