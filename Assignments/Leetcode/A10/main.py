class Solution:
    def kClosest(self, points: List[List[int]], k: int) -> List[List[int]]:
        distances = []
        for point in points:
            distance = (point[0]**2 + point[1]**2) ** 0.5
            distances.append((distance, point))
        
        distances.sort()
        
        result = []
        for i in range(k):
            result.append(distances[i][1])
        
        return result
        
