# 587. Erect the Fence
### Question
You are given an array trees where trees[i] = [xi, yi] represents the location of a tree in the garden.
Fence the entire garden using the minimum length of rope, as it is expensive. The garden is well-fenced only if all the trees are enclosed.
Return the coordinates of trees that are exactly located on the fence perimeter. You may return the answer in any order.

### Output
Example 1:
![erect2-plane](https://github.com/user-attachments/assets/42b4647d-6c84-4d37-9a1e-d1e295e3f6e4)


Input: trees = [[1,1],[2,2],[2,0],[2,4],[3,3],[4,2]]
Output: [[1,1],[2,0],[4,2],[3,3],[2,4]]
Explanation: All the trees will be on the perimeter of the fence except the tree at [2, 2], which will be inside the fence.
Example 2:

![erect1-plane](https://github.com/user-attachments/assets/0f0323fe-ff1e-4937-9720-91c3faecd262)

Input: trees = [[1,2],[2,2],[4,2]]
Output: [[4,2],[2,2],[1,2]]
Explanation: The fence forms a line that passes through all the trees.

### Constraints:
```
1 <= trees.length <= 3000
trees[i].length == 2
0 <= xi, yi <= 100
All the given positions are unique.
```

### Files

|  #  | File Link | Assignment Description |
| :-: | ----------- | ---------------------- |
|  0  | [P587.md](https://github.com/Sudhir0228/4883-Programming_Techniques_Ray/blob/main/Assignments/Leetcode/A09/P587.md)     | PDF file of the problem.          |
|  1  | [main.py](https://github.com/Sudhir0228/4883-Programming_Techniques_Ray/blob/main/Assignments/Leetcode/A09/main.py)     | Solution file of the problem.          |
|  2  | [TestCase.md](https://github.com/Sudhir0228/4883-Programming_Techniques_Ray/blob/main/Assignments/Leetcode/A09/TestCase.md)     | Test Cases of the Problem with expected Output          |

