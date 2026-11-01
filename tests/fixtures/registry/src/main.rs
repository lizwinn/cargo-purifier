fn main() {
    let mut buffer = itoa::Buffer::new();
    println!("counted {}", buffer.format(42));
}
