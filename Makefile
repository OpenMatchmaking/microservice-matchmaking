shell:
	iex -S mix

rebuild:
	mix clean && mix compile

tests:
	mix test
