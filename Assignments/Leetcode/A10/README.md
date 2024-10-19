# 973. K Closest Points to Origin
### Question
Given an array of points where points[i] = [xi, yi] represents a point on the X-Y plane and an integer k, return the k closest points to the origin (0, 0).
The distance between two points on the X-Y plane is the Euclidean distance (i.e., √(x1 - x2)2 + (y1 - y2)2).
You may return the answer in any order. The answer is guaranteed to be unique (except for the order that it is in).

### Output
Example 1:
Input: points = [[1,3],[-2,2]], k = 1
Output: [[-2,2]]
Explanation:
The distance between (1, 3) and the origin is sqrt(10).
The distance between (-2, 2) and the origin is sqrt(8).
Since sqrt(8) < sqrt(10), (-2, 2) is closer to the origin.
We only want the closest k = 1 points from the origin, so the answer is just [[-2,2]].

Example 2:
Input: points = [[3,3],[5,-1],[-2,4]], k = 2
Output: [[3,3],[-2,4]]
Explanation: The answer [[-2,4],[3,3]] would also be accepted.


### Constraints:
```
1 <= k <= points.length <= 104
-104 <= xi, yi <= 104
```

### Files

|  #  | File Link | Assignment Description |
| :-: | ----------- | ---------------------- |
|  0  | [P973](https://github.com/Sudhir0228/4883-Programming_Techniques_Ray/blob/main/Assignments/Leetcode/A10/P793)     | PDF file of the problem.          |
|  1  | [main.py](https://github.com/Sudhir0228/4883-Programming_Techniques_Ray/blob/main/Assignments/Leetcode/A10/main.py)     | Solution file of the problem.          |
|  2  | [TestCase](https://github.com/Sudhir0228/4883-Programming_Techniques_Ray/blob/main/Assignments/Leetcode/A10/TestCase)     | Test Cases of the Problem with expected Output          |




