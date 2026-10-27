.PHONY: up build status demo logs down reset ps

up:
	docker compose up -d --build

build:
	docker compose build

status:
	./scripts/status.sh

demo:
	./scripts/demo.sh

logs:
	docker compose logs -f --tail=100

ps:
	docker compose ps

down:
	docker compose down

reset:
	docker compose down -v
	docker compose up -d --build
