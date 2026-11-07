.PHONY: all build sign clean

all: build

build:
	swift build
	@if [ -x "../scripts/sign-binary.sh" ]; then \
		../scripts/sign-binary.sh "$$(swift build --show-bin-path)/mousebridge-helper" com.mousebridge.helper; \
	fi

clean:
	rm -rf .build
