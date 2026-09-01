// The topic picker's rows.
//
// Built ONCE PER SYSTEM, not once per render. The python memoises the four naming functions because
// a yappi profile of a 60-user minute counted 37,868 calls to `datastar_kebab`, 25,236 to
// `topic_slug` and 12,632 to `topic_signal_key` -- five regex passes each, recomputed every render,
// for values that are pure functions of a topic name that never changes within a process. The Go
// port caches the derived rows behind a lock; here they are built during boot, before any shard
// comes up, so there is nothing to cache and nothing to lock.
package render

import "../corpus"
import "core:strings"

Topic_Choice :: struct {
	name:        string,
	slug:        string, // the attribute form: `data-bind:topics.<slug>`
	key:         string, // what that binding writes into the signal store
	description: string,
	bind:        string, // the whole attribute, so the writer does not rebuild it per render
}

// The rows for one system, in file order -- which is the order the picker renders them in.
build_topic_choices :: proc(system: ^corpus.System, allocator := context.allocator) -> []Topic_Choice {
	choices := make([]Topic_Choice, len(system.topics.list), allocator)
	for topic, index in system.topics.list {
		slug := topic_slug(topic.name, allocator)
		choices[index] = Topic_Choice {
			name        = topic.name,
			slug        = slug,
			key         = datastar_camel(slug, allocator),
			description = topic.description,
			bind        = strings.concatenate({"data-bind:topics.", slug}, allocator),
		}
	}
	return choices
}
