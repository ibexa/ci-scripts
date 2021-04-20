<?php

/**
 * @copyright Copyright (C) Ibexa AS. All rights reserved.
 * @license For full copyright and license information view LICENSE file distributed with this source code.
 */
declare(strict_types=1);

namespace Ibexa\Platform\ContiniousIntegrationScripts\Command;

use Cz\Git\GitRepository;
use Github\Client;
use Ibexa\Platform\ContiniousIntegrationScripts\Helper\ComposerHelper;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;
use Symfony\Component\Filesystem\Filesystem;

class RunRegressionCommand extends Command
{
    private const REPO_OWNER = 'mnocon';

    private const REPO_NAME = 'ezplatform-page-builder';

    private const COMMIT_MESSAGE = '[TMP] Run Regression';

    /** @var ?string */
    private $token;

    protected function interact(InputInterface $input, OutputInterface $output): void
    {
        $io = new SymfonyStyle($input, $output);

        if (!$input->getArgument('token')) {
            $input->setArgument('token', ComposerHelper::getGitHubToken());
        }

        if (!$input->getArgument('productVersion')) {
            $productVersion = $io->ask('Please enter the Ibexa DXP version', '3.3', static function (string $answer): string {
                if (preg_match('/(\d+)\.(\d+)/', $answer) === 0) {
                    throw new \RuntimeException(
                        sprintf(
                            'Unregognised version format: %s. Please use format X.Y instead, e.g. 3.3',
                        $answer)
                    );
                }

                return $answer;
            });

            $input->setArgument('productVersion', $productVersion);
        }
    }

    public function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);
        $this->token = $input->getArgument('token');
        $productVersion = $input->getArgument('productVersion');

        $this->validate();

        $pageBuilderBaseBranch = $this->mapProductVersionToPageBuilder($productVersion);
        $regressionBranchName = uniqid('tmp_regression_', true);

        $repo = GitRepository::cloneRepository(
            sprintf('https://github.com/%s/%s.git', self::REPO_OWNER, self::REPO_NAME),
            null, ['-b' => $pageBuilderBaseBranch]
        );
        $repo->createBranch($regressionBranchName, true);
        $repo->removeBranch($pageBuilderBaseBranch);

        copy(LinkDependenciesCommand::DEPENDENCIES_FILE, self::REPO_NAME . \DIRECTORY_SEPARATOR . LinkDependenciesCommand::DEPENDENCIES_FILE);

        $repo->addFile('dependencies.json');
        $repo->commit(self::COMMIT_MESSAGE);
        $repo->push('origin', [$regressionBranchName, '-u']);

        $io->success(sprintf('Successfuly pushed to %s/%s a branch called: %s', self::REPO_OWNER, self::REPO_NAME, $regressionBranchName));

        $client = new Client();
        if ($this->token) {
            $client->authenticate($this->token, null, Client::AUTH_ACCESS_TOKEN);
        }

        $this->waitUntilBranchExists($client, $regressionBranchName);

        $response = $client->pullRequests()->create(self::REPO_OWNER, self::REPO_NAME,
        [
            'title' => 'Run regression for IBX-XXXX',
            'base' => $pageBuilderBaseBranch,
            'head' => $regressionBranchName,
            'body' => 'Please add your description here.',
            'draft' => 'true',
        ]);

        $io->success(sprintf('Created PR, please see: %s', $response['_links']['html']['href']));

        if ($io->confirm(sprintf('Do you want to remove the created %s directory?', self::REPO_NAME), true)) {
            $fs = new Filesystem();
            $fs->remove(self::REPO_NAME);
        }

        return Command::SUCCESS;
    }

    protected function configure(): void
    {
        $this
            ->setName('regression:run')
            ->setDescription('Triggers a regression run on Travis')
            ->addArgument('productVersion', InputArgument::REQUIRED, 'Ibexa DXP version')
            ->addArgument('token', InputArgument::OPTIONAL, 'GitHub token')
        ;
    }

    private function validate(): void
    {
        if (!file_exists(LinkDependenciesCommand::DEPENDENCIES_FILE)) {
            throw new \RuntimeException(
                sprintf("File '%s' not found. Please run `php bin/travis dependencies:link` before running this Command", LinkDependenciesCommand::DEPENDENCIES_FILE)
            );
        }

        $dependenciesFile = file_get_contents(LinkDependenciesCommand::DEPENDENCIES_FILE);
        if ($dependenciesFile === false) {
            throw new \RuntimeException(
                sprintf('Unable to read the %s file', LinkDependenciesCommand::DEPENDENCIES_FILE)
            );
        }

        $dependencies = json_decode($dependenciesFile, true, 512, JSON_THROW_ON_ERROR);

        foreach ($dependencies as $dependency) {
            if ($dependency['package'] === 'ezsystems/ezplatform-page-builder') {
                throw new \RuntimeException(
                    sprintf(
                        'Page Builder dependency detected. Simply attach the %s file to that PR and use the commit messgae "%s"',
                        LinkDependenciesCommand::DEPENDENCIES_FILE,
                        self::COMMIT_MESSAGE
                    )
                );
            }
        }
    }

    private function mapProductVersionToPageBuilder(string $productVersion): string
    {
        switch ($productVersion) {
            case '3.3':
                return 'master';
            case '2.5':
            case '3.2':
            default:
                throw new \RuntimeException(
                    sprintf(
                        'Unsupported version %s. Please contact QA team',
                        $productVersion
                    ));
        }
    }

    private function waitUntilBranchExists(Client $client, string $branchNme): void
    {
        $counter = 0;
        $success = false;
        while ($counter < 5) {
            try {
                $client->repo()->branches(self::REPO_OWNER, self::REPO_NAME, $branchNme);
                $success = true;
                break;
            } catch (\RuntimeException $e) {
                sleep(1);
                ++$counter;
            }
        }

        if (!$success) {
            throw new \RuntimeException('Pushed branch not found using GitHub API.');
        }
    }
}
