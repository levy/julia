# Never tracked. A method on the tracked type `Corner`: an edit of the fields
# of `Corner` is refused, because this dependent is out of reach.
corner_of(c::Corner) = c.k
