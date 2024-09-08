/**
 * Name: Sudhir Ray
 * Course: 4883-Programming_Techniques
 * Date: 09/07/2024
 */
#include <iostream>

using namespace std;

int main() { 
   int T;
   int a;
   int b;
   int sum=0;
   int j=0;
   cin>>T;
   while(T--){
      sum=0;
      cin>>a;
      cin>>b;
      for(int i=a;i<=b;i++){

         if(i % 2 == 1){
            sum += i;
         }
      }
      cout<<"Case "<<++j<<": "<<sum<<endl;
   }
}  
