class Solution:
    def findKthLargest(self, nums: List[int], k: int) -> int:
        queue = deque()
        
        for number in nums:
            
            if not queue or number >= queue[-1]:
                queue.append(number)  
            else:
                for i in range(len(queue)):
                    if number < queue[i]:
                        queue.insert(i, number)
                        break
           
            if len(queue) > k:
                queue.popleft()  

        return queue[0]
        
        
