# rustls-native-certs: wasix patch, floored across the range (a version the floor no longer fits hard-fails).
{...}: {
  edited = ["=0.6.3" ">=0.8.1"];
  stock = ["<0.6.3" ">0.6.3, <0.8.1"];
}
