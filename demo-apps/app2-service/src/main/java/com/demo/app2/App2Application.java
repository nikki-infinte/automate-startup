package com.demo.app2;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.core.env.Environment;

@SpringBootApplication
public class App2Application {

    private static final Logger log = LoggerFactory.getLogger(App2Application.class);
    private final Environment env;

    public App2Application(Environment env) {
        this.env = env;
    }

    public static void main(String[] args) {
        SpringApplication.run(App2Application.class, args);
    }

    @EventListener(ApplicationReadyEvent.class)
    public void onReady() {
        String name = env.getProperty("spring.application.name", "app2-service");
        String port = env.getProperty("local.server.port", env.getProperty("server.port", "8082"));
        log.info("============================================================");
        log.info("  {} is running on http://localhost:{}", name, port);
        log.info("  Health     : http://localhost:{}/api/health", port);
        log.info("  Check App1 : http://localhost:{}/api/check-app1", port);
        log.info("============================================================");
    }
}
