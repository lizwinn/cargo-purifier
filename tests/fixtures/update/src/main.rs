fn main() {
    let mut buffer = itoa::Buffer::new();
    println!("pinned {}", buffer.format(1));
}
