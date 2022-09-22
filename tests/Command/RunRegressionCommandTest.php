<?php

namespace Ibexa\Tests\ContiniousIntegrationScripts\Command;

use Ibexa\ContiniousIntegrationScripts\Command\RunRegressionCommand;
use PHPUnit\Framework\Assert;
use PHPUnit\Framework\TestCase;

class RunRegressionCommandTest extends TestCase
{
    public function testIsInitializable(): void
    {
        Assert::assertInstanceOf(RunRegressionCommand::class, new RunRegressionCommand());
    }
}