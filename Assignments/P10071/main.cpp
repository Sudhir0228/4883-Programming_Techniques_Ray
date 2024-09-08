/**
 * Name: Sudhir Ray
 * Course: 4883-Programming_Techniques
 * Date: 09/07/2024
 */

#include <iostream>
using namespace std;

using namespace std;

int main() {
  int velocity = 0, time = 0;
  int displacement = 0;

  while (cin >> velocity >> time) {
    displacement = velocity * time * 2;
    cout << displacement << endl;
  }
}
