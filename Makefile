all: README.md

README.md: src/TinyRPC.jl
	julia --project -e 'using TinyRPC; println(Docs.doc(TinyRPC))' > README.md
