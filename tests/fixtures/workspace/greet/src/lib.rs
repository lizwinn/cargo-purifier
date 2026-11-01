// A library from crates.io (itoa) inside a workspace package.
pub fn greeting(crates: u64) -> String {
    let mut buffer = itoa::Buffer::new();
    format!("hello from {} crates", buffer.format(crates))
}

#[cfg(test)]
mod tests {
    #[test]
    fn counts_crates() {
        assert_eq!(super::greeting(2), "hello from 2 crates");
    }
}
