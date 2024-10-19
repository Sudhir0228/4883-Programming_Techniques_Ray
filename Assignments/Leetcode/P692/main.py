class Solution:
    def topKFrequent(self, words: List[str], k: int) -> List[str]:
        count = {}
        for word in words:
            count[word] = count.get(word, 0) + 1

        word_freq = list(count.items())

        word_freq.sort()
        word_freq.sort(key=lambda x: x[1], reverse=True)
        '''
        n = len(word_freq)
        for i in range(n):
            for j in range(0, n - i - 1):
                if word_freq[j][1] < word_freq[j + 1][1]:
                    word_freq[j], word_freq[j + 1] = word_freq[j + 1], word_freq[j]
                elif word_freq[j][1] == word_freq[j + 1][1] and word_freq[j][0] > word_freq[j + 1][0]:
                    word_freq[j], word_freq[j + 1] = word_freq[j + 1], word_freq[j]
      
        '''

        result = []
        for i in range(k):
            result.append(word_freq[i][0])

        return result
