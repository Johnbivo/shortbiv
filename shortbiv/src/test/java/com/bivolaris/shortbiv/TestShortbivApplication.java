package com.bivolaris.shortbiv;

import org.springframework.boot.SpringApplication;

public class TestShortbivApplication {

	public static void main(String[] args) {
		SpringApplication.from(ShortbivApplication::main).with(TestcontainersConfiguration.class).run(args);
	}

}
