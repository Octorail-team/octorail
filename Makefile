# Default Ruby for day-to-day work; override with `make test RUBY=ruby34`.
RUBY ?= ruby33
RUBIES := ruby33 ruby34 ruby40
RUN := docker compose run --rm

.PHONY: build install test test-all lint lint-fix console shell bench bench-nojit

build:
	docker compose build

install:
	$(RUN) $(RUBY) bundle install

test: install
	$(RUN) $(RUBY) bundle exec rspec $(ARGS)

test-all:
	@for r in $(RUBIES); do \
		echo "==> $$r"; \
		$(RUN) $$r sh -c "bundle install --quiet && bundle exec rspec" || exit 1; \
	done

lint: install
	$(RUN) $(RUBY) bundle exec rubocop

lint-fix: install
	$(RUN) $(RUBY) bundle exec rubocop -a

console: install
	$(RUN) $(RUBY) bin/console

shell:
	$(RUN) $(RUBY) bash

# BENCH_ONLY=nested runs only the scenarios whose title contains that text.
BENCH_RUN := docker compose run --rm -e BUNDLE_GEMFILE=/gem/bench/Gemfile -e BENCH_ONLY=$(BENCH_ONLY)

bench:
	$(BENCH_RUN) $(RUBY) sh -c "rm -f bench/Gemfile.lock && bundle install --quiet && ruby bench/run.rb"

bench-nojit:
	$(BENCH_RUN) -e RUBY_YJIT_ENABLE=0 $(RUBY) sh -c "rm -f bench/Gemfile.lock && bundle install --quiet && ruby bench/run.rb"
