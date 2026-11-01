fn main() {
    let mut buffer = ryu::Buffer::new();
    println!("{} and {}", greet::greeting(2), buffer.format(1.5));
}
