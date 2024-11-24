# 886. Possible Bipartition
### Question
We want to split a group of n people (labeled from 1 to n) into two groups of any size. Each person may dislike some other people, and they should not go into the same group.
Given the integer n and the array dislikes where dislikes[i] = [ai, bi] indicates that the person labeled ai does not like the person labeled bi, return true if it is possible to split everyone into two groups in this way.

### Output
Example 1:
Input: n = 4, dislikes = [[1,2],[1,3],[2,4]]
Output: true
Explanation: The first group has [1,4], and the second group has [2,3].

Example 2:
Input: n = 3, dislikes = [[1,2],[1,3],[2,3]]
Output: false
Explanation: We need at least 3 groups to divide them. We cannot put them in two groups.


### Constraints:
```
1 <= n <= 2000
0 <= dislikes.length <= 104
dislikes[i].length == 2
1 <= ai < bi <= n
All the pairs of dislikes are unique.
```

### Files

|  #  | File Link | Assignment Description |
| :-: | ----------- | ---------------------- |
|  0  | [P886](https://github.com/Sudhir0228/4883-Programming_Techniques_Ray/blob/main/Assignments/Leetcode/A11/P886)     | PDF file of the problem.          |
|  1  | [main.py](https://github.com/Sudhir0228/4883-Programming_Techniques_Ray/blob/main/Assignments/Leetcode/A11/main.py)     | Solution file of the problem.          |
|  2  | [TestCase](https://github.com/Sudhir0228/4883-Programming_Techniques_Ray/blob/main/Assignments/Leetcode/A11/TestCase)     | Test Cases of the Problem with expected Output          |




