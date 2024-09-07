/**
 * Name: Sudhir Ray
 * Course: 4883-Programming_Techniques
 * Date: 09/06/2024
 */
#include <iostream>
using namespace std;

using namespace std;

int main() {
  long B = 0, A = 0;
  long difference = 0;

  while (cin >> A >> B) {
    if (A > B) {
      difference = A - B;
    } else if (B > A) {
      difference = B - A;
    }
    cout << difference << endl;
  }
}
