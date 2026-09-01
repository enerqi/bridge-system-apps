// A group-of-slices container with two allocations instead of one per group.
//
// An auction is a list of POSITIONS, and a position is a list of the calls it allows -- one for an
// ordinary call, several for `2D/2H`. Written the obvious way that is a `[][]Bid`, and the inner
// slice is where the memory goes: the swedish system prepares to about 380,000 positions and almost
// every one holds exactly one call, so the obvious shape spends 380,000 allocations and 16 bytes of
// slice header on each 6-byte payload.
//
// This stores the items end to end and remembers where each group stops, which is two allocations
// per auction -- and, once the corpus packs every auction into one of these, two for the lot. The
// matcher then walks contiguous memory.
package flat

// Groups of T, stored flat. `ends` holds the exclusive end offset of each group, so group `i` is
// `items[ends[i - 1] : ends[i]]` and the first group starts at zero.
Flat :: struct($T: typeid) {
	items: [dynamic]T,
	ends:  [dynamic]u32,
}

make_flat :: proc($T: typeid, groups, items: int, allocator := context.allocator) -> Flat(T) {
	return Flat(T){items = make([dynamic]T, 0, items, allocator), ends = make([dynamic]u32, 0, groups, allocator)}
}

destroy :: proc(collection: ^Flat($T)) {
	delete(collection.items)
	delete(collection.ends)
}

// How many groups.
group_count :: #force_inline proc(collection: Flat($T)) -> int {
	return len(collection.ends)
}

is_empty :: #force_inline proc(collection: Flat($T)) -> bool {
	return len(collection.ends) == 0
}

// How many items across every group.
item_count :: #force_inline proc(collection: Flat($T)) -> int {
	return len(collection.items)
}

push_group :: proc(collection: ^Flat($T), group: []T) {
	append(&collection.items, ..group)
	append(&collection.ends, u32(len(collection.items)))
}

// Add to the group currently being built. Pair with `close_group`; for the cases where a group's
// contents come from a loop that can also produce nothing.
push_item :: proc(collection: ^Flat($T), item: T) {
	append(&collection.items, item)
}

// How many items the group being built holds so far. A caller uses this to tell "the loop produced
// nothing" from "the loop produced something", which is the difference between a parse error and a
// position, and cannot be recovered after the group is closed.
open_len :: proc(collection: Flat($T)) -> int {
	start := len(collection.ends) == 0 ? 0 : int(collection.ends[len(collection.ends) - 1])
	return len(collection.items) - start
}

close_group :: proc(collection: ^Flat($T)) {
	append(&collection.ends, u32(len(collection.items)))
}

// Group `index`, as a slice into the shared backing array. Borrowed, not owned: it is invalidated
// by any later push, the same as any slice of a dynamic array.
group :: proc(collection: Flat($T), index: int) -> []T {
	start := index == 0 ? 0 : int(collection.ends[index - 1])
	return collection.items[start:collection.ends[index]]
}

// Append every group of `source` to `destination`, keeping the group boundaries. Returns the index
// the first copied group landed at, which is how the corpus records where an auction starts once
// they are all packed into one collection.
extend :: proc(destination: ^Flat($T), source: Flat(T)) -> (first_group: int) {
	first_group = len(destination.ends)
	offset := u32(len(destination.items))
	append(&destination.items, ..source.items[:])
	for end in source.ends {
		append(&destination.ends, offset + end)
	}
	return first_group
}

clear_flat :: proc(collection: ^Flat($T)) {
	clear(&collection.items)
	clear(&collection.ends)
}

// Append the first `count` groups of `source` to `destination`. Used where a group has to be
// rebuilt: the caller copies everything up to it, then pushes the replacement.
extend_prefix :: proc(destination: ^Flat($T), source: Flat(T), count: int) {
	if count <= 0 {
		return
	}
	limit := min(count, len(source.ends))
	offset := u32(len(destination.items))
	append(&destination.items, ..source.items[:source.ends[limit - 1]])
	for index in 0 ..< limit {
		append(&destination.ends, offset + source.ends[index])
	}
}

// A deep copy: same groups, own backing arrays.
clone :: proc(source: Flat($T), allocator := context.allocator) -> Flat(T) {
	out := make_flat(T, len(source.ends), len(source.items), allocator)
	append(&out.items, ..source.items[:])
	append(&out.ends, ..source.ends[:])
	return out
}
