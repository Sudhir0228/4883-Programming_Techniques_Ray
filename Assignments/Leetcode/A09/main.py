class Solution:
    def outerTrees(self, trees: List[List[int]]) -> List[List[int]]:
        def cross(p, q, r):
            return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])
        
        points = sorted(trees)
        lower, upper = [], []

        for p in points:
            while len(lower) >= 2 and cross(lower[-2], lower[-1], p) < 0:
                lower.pop()
            lower.append(p)

        for p in reversed(points):
            while len(upper) >= 2 and cross(upper[-2], upper[-1], p) < 0:
                upper.pop()
            upper.append(p)

        return list(set(tuple(p) for p in (lower + upper)))
