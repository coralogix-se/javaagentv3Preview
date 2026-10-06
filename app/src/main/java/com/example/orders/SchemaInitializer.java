package com.example.orders;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationRunner;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcTemplate;

@Configuration
public class SchemaInitializer {
  private static final Logger log = LoggerFactory.getLogger(SchemaInitializer.class);

  @Bean
  ApplicationRunner initSchema(JdbcTemplate jdbc) {
    return args -> {
      for (int attempt = 1; attempt <= 30; attempt++) {
        try {
          jdbc.execute("CREATE SCHEMA IF NOT EXISTS shop");
          jdbc.execute(
              """
              CREATE TABLE IF NOT EXISTS shop.orders (
                id BIGSERIAL PRIMARY KEY,
                sku TEXT NOT NULL,
                qty INT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
              )
              """);
          log.atInfo().addKeyValue("schema", "shop").log("orders schema ready");
          return;
        } catch (RuntimeException ex) {
          log.atWarn()
              .addKeyValue("attempt", attempt)
              .setCause(ex)
              .log("waiting for postgres");
          Thread.sleep(2000);
        }
      }
      throw new IllegalStateException("postgres did not become ready");
    };
  }
}
