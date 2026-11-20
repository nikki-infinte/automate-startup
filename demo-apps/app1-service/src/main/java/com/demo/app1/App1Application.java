package com.demo.app1;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.core.env.Environment;

@SpringBootApplication
public class App1Application {

    private static final Logger log = LoggerFactory.getLogger(App1Application.class);
    private final Environment env;

    public App1Application(Environment env) {
        this.env = env;
    }

    public static void main(String[] args) {
        SpringApplication.run(App1Application.class, args);
    }

    @EventListener(ApplicationReadyEvent.class)
    public void onReady() {
        String name = env.getProperty("spring.application.name", "app1-service");
        String port = env.getProperty("local.server.port", env.getProperty("server.port", "8081"));
        log.info("============================================================");
        log.info("  {} is running on http://localhost:{}", name, port);
        log.info("  Health : http://localhost:{}/api/health", port);
        log.info("============================================================");
    }
}
