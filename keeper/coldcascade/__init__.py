"""The keeper never touches a quote. It writes one trusted word (the map), pokes one cache,
reads fills back off the Substreams stream to compute markouts, and drives the replay."""
